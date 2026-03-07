package Typist::Static::Checker;
use v5.40;

our $VERSION = '0.01';

use Typist::Registry;
use Typist::Parser;
use Typist::Error;
use Typist::Error::Global;
use Typist::Kind;
use Typist::KindChecker;
use Typist::Static::Timing qw(start_timing record_timing accumulate_timing);
use Typist::Type::Fold;
use Scalar::Util qw(refaddr);

# ── Constructor ──────────────────────────────────

sub new ($class, %args) {
    bless +{
        registry  => $args{registry} // 'Typist::Registry',
        errors    => $args{errors}   // 'Typist::Error::Global',
        extracted => $args{extracted},
        file      => $args{file}     // '(buffer)',
        timings   => $args{timings},
        _fn_line_cache => +{},
        _type_wf_cache => +{},
        _free_vars_cache => +{},
    }, $class;
}

# ── CHECK-phase Static Analysis ─────────────────

sub analyze ($self) {
    my $timings = $self->{timings};

    my $t0 = start_timing($timings);
    $self->_check_aliases;
    record_timing($timings, aliases => $t0);

    $t0 = start_timing($timings);
    $self->_check_functions;
    record_timing($timings, functions => $t0);

    $t0 = start_timing($timings);
    $self->_check_typeclasses;
    record_timing($timings, typeclasses => $t0);

    $t0 = start_timing($timings);
    $self->_check_protocols;
    record_timing($timings, protocols => $t0);
}

# ── Source Location Helpers ─────────────────────

sub _alias_line ($self, $name) {
    my $ext = $self->{extracted} // return (0, '(alias definition)', 0);
    my $info = $ext->{aliases}{$name} // return (0, '(alias definition)', 0);
    ($info->{line}, $self->{file}, $info->{col} // 0);
}

sub _fn_line ($self, $fqn) {
    if (my $cached = $self->{_fn_line_cache}{$fqn}) {
        return @$cached;
    }

    my $ext = $self->{extracted} // return (0, '(function signature)', 0);
    my $bare = $fqn =~ s/\A.*:://r;
    my $info = $ext->{functions}{$bare} // return (0, '(function signature)', 0);
    my @loc = ($info->{line}, $self->{file}, $info->{col} // 0);
    $self->{_fn_line_cache}{$fqn} = \@loc;
    @loc;
}

sub _tc_line ($self, $name) {
    my $ext = $self->{extracted} // return (0, '(typeclass definition)', 0);
    my $info = $ext->{typeclasses}{$name} // return (0, '(typeclass definition)', 0);
    ($info->{line}, $self->{file}, $info->{col} // 0);
}

# ── Alias Validation ────────────────────────────

# Verify all aliases resolve without cycles.
sub _check_aliases ($self) {
    my %aliases = $self->{registry}->all_aliases;

    for my $name (sort keys %aliases) {
        my ($line, $file, $col) = $self->_alias_line($name);
        my $type = eval { $self->{registry}->lookup_type($name) };
        if ($@) {
            if ($@ =~ /cycle/) {
                $self->{errors}->collect(
                    kind    => 'CycleError',
                    message => "Alias cycle detected involving '$name'",
                    file    => $file,
                    line    => $line,
                    col     => $col,
                );
            } else {
                $self->{errors}->collect(
                    kind    => 'ResolveError',
                    message => "Failed to resolve alias '$name': $@",
                    file    => $file,
                    line    => $line,
                    col     => $col,
                );
            }
        }
    }
}

# ── Function Signature Validation ───────────────

# Verify all type vars in params/returns are declared in :Generic.
sub _check_functions ($self) {
    my %functions = $self->{registry}->all_functions;
    my $timings = $self->{timings};

    for my $fqn (sort keys %functions) {
        my $t_sig = start_timing($timings);
        my $sig = $functions{$fqn};
        my ($fn_line, $fn_file, $fn_col) = $self->_fn_line($fqn);
        my %declared = map { $_->{name} => 1 }
                       ($sig->{generics} // [])->@*;

        # Collect unique free type variables from params and returns
        my $t_phase = start_timing($timings);
        my %seen_free;
        for my $ptype (($sig->{params} // [])->@*) {
            $seen_free{$_} = 1 for $self->_free_vars_of($ptype);
        }
        if ($sig->{returns}) {
            $seen_free{$_} = 1 for $self->_free_vars_of($sig->{returns});
        }
        accumulate_timing($timings, 'functions.free_vars', $t_phase);

        # Check each free variable is declared
        $t_phase = start_timing($timings);
        for my $var (sort keys %seen_free) {
            unless ($declared{$var}) {
                $self->{errors}->collect(
                    kind    => 'UndeclaredTypeVar',
                    message => "Type variable '$var' in $fqn is not declared in generics",
                    file    => $fn_file,
                    line    => $fn_line,
                    col     => $fn_col,
                );
            }
        }
        accumulate_timing($timings, 'functions.undeclared_vars', $t_phase);

        # Validate effect annotations
        $t_phase = start_timing($timings);
        if ($sig->{effects}) {
            $self->_check_effect_wellformed($sig->{effects}, $fqn, \%declared);
        }
        accumulate_timing($timings, 'functions.effects', $t_phase);

        # Validate bound expressions are well-formed
        $t_phase = start_timing($timings);
        for my $g (($sig->{generics} // [])->@*) {
            next unless ref $g eq 'HASH' && $g->{bound_expr};
            my $bound_type = eval { Typist::Parser->parse($g->{bound_expr}) };
            if ($@) {
                $self->{errors}->collect(
                    kind    => 'InvalidBound',
                    message => "Invalid bound expression '$g->{bound_expr}' for $g->{name} in $fqn: $@",
                    file    => $fn_file,
                    line    => $fn_line,
                    col     => $fn_col,
                );
            } elsif ($bound_type) {
                $self->_check_type_wellformed($bound_type, $fqn);
            }
        }
        accumulate_timing($timings, 'functions.bounds', $t_phase);

        # Validate that param/return type expressions are well-formed
        $t_phase = start_timing($timings);
        $self->_check_type_wellformed($_, $fqn) for ($sig->{params} // [])->@*;
        $self->_check_type_wellformed($sig->{returns}, $fqn) if $sig->{returns};
        accumulate_timing($timings, 'functions.type_wellformed', $t_phase);

        # Kind well-formedness: verify type expressions respect declared kinds
        $t_phase = start_timing($timings);
        my %var_kinds;
        for my $g (($sig->{generics} // [])->@*) {
            next unless ref $g eq 'HASH' && $g->{var_kind};
            $var_kinds{$g->{name}} = $g->{var_kind};
        }
        if (%var_kinds) {
            for my $ptype (($sig->{params} // [])->@*) {
                eval { Typist::KindChecker->infer_kind($ptype, \%var_kinds) };
                if ($@) {
                    $self->{errors}->collect(
                        kind    => 'KindError',
                        message => "Kind error in parameter of $fqn: $@",
                        file    => $fn_file,
                        line    => $fn_line,
                        col     => $fn_col,
                    );
                }
            }
            if ($sig->{returns}) {
                eval { Typist::KindChecker->infer_kind($sig->{returns}, \%var_kinds) };
                if ($@) {
                    $self->{errors}->collect(
                        kind    => 'KindError',
                        message => "Kind error in return type of $fqn: $@",
                        file    => $fn_file,
                        line    => $fn_line,
                        col     => $fn_col,
                    );
                }
            }
        }
        accumulate_timing($timings, 'functions.kinds', $t_phase);
        accumulate_timing($timings, 'functions.total', $t_sig);
    }
}

# ── Type Well-formedness ────────────────────────

sub _check_type_wellformed ($self, $type, $context) {
    return unless $type;

    my ($ctx_line, $ctx_file, $ctx_col) = $self->_fn_line($context);
    my @unknown_aliases = $self->_unknown_aliases_in_type($type);

    for my $name (@unknown_aliases) {
        $self->{errors}->collect(
            kind    => 'UnknownType',
            message => "Type alias '$name' is not defined (in $context)",
            file    => $ctx_file,
            line    => $ctx_line,
            col     => $ctx_col,
        );
    }
}

sub _unknown_aliases_in_type ($self, $type) {
    my $cache_key = ref $type ? refaddr($type) : "$type";
    if (exists $self->{_type_wf_cache}{$cache_key}) {
        return $self->{_type_wf_cache}{$cache_key}->@*;
    }

    my @unknown;
    Typist::Type::Fold->walk($type, sub ($node) {
        return unless $node->is_alias;
        my $name = $node->alias_name;
        return if $self->{registry}->has_alias($name);
        return if $self->{registry}->has_typeclass($name);
        return if $self->{registry}->lookup_effect($name);
        push @unknown, $name;
    });

    $self->{_type_wf_cache}{$cache_key} = \@unknown;
    @unknown;
}

sub _free_vars_of ($self, $type) {
    my $cache_key = ref $type ? refaddr($type) : "$type";
    if (exists $self->{_free_vars_cache}{$cache_key}) {
        return $self->{_free_vars_cache}{$cache_key}->@*;
    }

    my @free = $type->free_vars;
    $self->{_free_vars_cache}{$cache_key} = \@free;
    @free;
}

# ── Effect Well-formedness ────────────────────────

sub _check_effect_wellformed ($self, $eff, $context, $declared_vars) {
    my $row = $eff->is_eff ? $eff->row : $eff;
    return unless $row->is_row;

    my ($ctx_line, $ctx_file, $ctx_col) = $self->_fn_line($context);

    # Check labels are registered effects
    for my $label ($row->labels) {
        unless ($self->{registry}->is_effect_label($label)) {
            $self->{errors}->collect(
                kind    => 'UnknownEffect',
                message => "Effect '$label' is not defined (in $context)",
                file    => $ctx_file,
                line    => $ctx_line,
                col     => $ctx_col,
            );
        }
    }

    # Check row variable is declared in :Generic
    # '*' is an internal marker for unannotated functions (any effect)
    if (defined $row->row_var_name && $row->row_var_name ne '*') {
        unless ($declared_vars->{$row->row_var_name}) {
            $self->{errors}->collect(
                kind    => 'UndeclaredRowVar',
                message => "Row variable '" . $row->row_var_name . "' in $context is not declared in generics",
                file    => $ctx_file,
                line    => $ctx_line,
                col     => $ctx_col,
            );
        }
    }
}

# ── TypeClass Superclass Validation ────────────

sub _check_typeclasses ($self) {
    my %typeclasses = $self->{registry}->all_typeclasses;

    # Check superclass references are valid
    for my $name (sort keys %typeclasses) {
        my $def = $typeclasses{$name} // next;
        my ($tc_line, $tc_file, $tc_col) = $self->_tc_line($name);
        for my $super ($def->supers) {
            unless ($self->{registry}->has_typeclass($super)) {
                $self->{errors}->collect(
                    kind    => 'UnknownTypeClass',
                    message => "Superclass '$super' of typeclass '$name' is not defined",
                    file    => $tc_file,
                    line    => $tc_line,
                    col     => $tc_col,
                );
            }
        }
    }

    # Detect superclass cycles via DFS
    my %visited;
    my %visiting;

    my $visit;
    $visit = sub ($tc_name) {
        return if $visited{$tc_name};
        if ($visiting{$tc_name}) {
            my ($cyc_line, $cyc_file, $cyc_col) = $self->_tc_line($tc_name);
            $self->{errors}->collect(
                kind    => 'CycleError',
                message => "Superclass cycle detected involving '$tc_name'",
                file    => $cyc_file,
                line    => $cyc_line,
                col     => $cyc_col,
            );
            return;
        }
        $visiting{$tc_name} = 1;
        my $def = $typeclasses{$tc_name};
        if ($def) {
            $visit->($_) for $def->supers;
        }
        delete $visiting{$tc_name};
        $visited{$tc_name} = 1;
    };

    $visit->($_) for sort keys %typeclasses;
}

# ── Protocol Well-formedness ─────────────────────

sub _eff_line ($self, $name) {
    my $ext = $self->{extracted} // return (0, '(effect definition)', 0);
    my $info = $ext->{effects}{$name} // return (0, '(effect definition)', 0);
    ($info->{line}, $self->{file}, $info->{col} // 0);
}

sub _check_protocols ($self) {
    my %effects = $self->{registry}->all_effects;

    for my $name (sort keys %effects) {
        my $eff = $effects{$name} // next;
        next unless $eff->has_protocol;

        my $protocol = $eff->protocol;
        my ($eff_line, $eff_file, $eff_col) = $self->_eff_line($name);

        # Build the set of known states from the Protocol object.
        # If explicit states were provided at definition, Protocol stores them;
        # otherwise it infers from transitions (source + target states).
        my %known_states = map { $_ => 1 } $protocol->states;
        my $has_explicit_states = $protocol->has_explicit_states;

        # Check all transition targets are known states (* and _ are implicit)
        for my $from (keys $protocol->transitions->%*) {
            for my $op (keys $protocol->transitions->{$from}->%*) {
                my $to = $protocol->transitions->{$from}{$op};
                next if $to eq '*';
                unless ($known_states{$to}) {
                    my $msg = $has_explicit_states
                        ? "Protocol $name: state '$to' appears in transitions "
                          . "but is not in the declared states list"
                        : "Protocol $name: transition from '$from' via '$op' "
                          . "targets undefined state '$to'";
                    $self->{errors}->collect(
                        kind    => 'ProtocolMismatch',
                        message => $msg,
                        file    => $eff_file,
                        line    => $eff_line,
                        col     => $eff_col,
                    );
                }
            }
        }

        # Also check source states against the explicit list (* is implicit)
        if ($has_explicit_states) {
            for my $from (keys $protocol->transitions->%*) {
                next if $from eq '*';
                unless ($known_states{$from}) {
                    $self->{errors}->collect(
                        kind    => 'ProtocolMismatch',
                        message => "Protocol $name: state '$from' appears in transitions "
                                 . "but is not in the declared states list",
                        file    => $eff_file,
                        line    => $eff_line,
                        col     => $eff_col,
                    );
                }
            }
        }

        # Check all effect operations are reachable from at least one state
        my @unreachable = $protocol->validate([$eff->op_names]);
        for my $op (@unreachable) {
            $self->{errors}->collect(
                kind    => 'ProtocolMismatch',
                message => "Protocol $name: operation '$op' is unreachable from any state",
                file    => $eff_file,
                line    => $eff_line,
                col     => $eff_col,
            );
        }
    }
}

1;

=head1 NAME

Typist::Static::Checker - CHECK-phase structural validation

=head1 DESCRIPTION

Validates structural well-formedness of type definitions, function signatures,
typeclass hierarchies, and effect protocols. Detects alias cycles, undeclared
type/row variables, unknown types and effects, kind errors, superclass cycles,
and protocol state-machine inconsistencies.

=head2 new

    my $checker = Typist::Static::Checker->new(
        registry  => $registry,
        errors    => $collector,
        extracted => $extracted,
        file      => $filename,
    );

Constructs a new Checker instance. C<registry> is a L<Typist::Registry>
(defaults to the class singleton). C<errors> is an error collector (defaults
to L<Typist::Error::Global>). C<extracted> is the hashref from
L<Typist::Static::Extractor>. C<file> is used for diagnostic locations.

=head2 analyze

    $checker->analyze;

Runs all structural checks: alias cycle detection, function signature
validation (undeclared type variables, bound expressions, kind
well-formedness, effect annotation well-formedness), typeclass superclass
validation (unknown references and cycle detection), and protocol
well-formedness (state consistency and operation reachability).

=cut
