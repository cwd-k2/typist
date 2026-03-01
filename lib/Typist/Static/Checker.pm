package Typist::Static::Checker;
use v5.40;

our $VERSION = '0.01';

use Typist::Registry;
use Typist::Parser;
use Typist::Error;
use Typist::Error::Global;
use Typist::Kind;
use Typist::KindChecker;
use Typist::Type::Fold;

# ── Constructor ──────────────────────────────────

sub new ($class, %args) {
    bless +{
        registry  => $args{registry} // 'Typist::Registry',
        errors    => $args{errors}   // 'Typist::Error::Global',
        extracted => $args{extracted},
        file      => $args{file}     // '(buffer)',
    }, $class;
}

# ── CHECK-phase Static Analysis ─────────────────

sub analyze ($self) {
    $self->_check_aliases;
    $self->_check_functions;
    $self->_check_typeclasses;
}

# ── Source Location Helpers ─────────────────────

sub _alias_line ($self, $name) {
    my $ext = $self->{extracted} // return (0, '(alias definition)', 0);
    my $info = $ext->{aliases}{$name} // return (0, '(alias definition)', 0);
    ($info->{line}, $self->{file}, $info->{col} // 0);
}

sub _fn_line ($self, $fqn) {
    my $ext = $self->{extracted} // return (0, '(function signature)', 0);
    my $bare = $fqn =~ s/\A.*:://r;
    my $info = $ext->{functions}{$bare} // return (0, '(function signature)', 0);
    ($info->{line}, $self->{file}, $info->{col} // 0);
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

    for my $fqn (sort keys %functions) {
        my $sig = $functions{$fqn};
        my ($fn_line, $fn_file, $fn_col) = $self->_fn_line($fqn);
        my %declared = map { $_->{name} => 1 }
                       ($sig->{generics} // [])->@*;

        # Collect unique free type variables from params and returns
        my %seen_free;
        for my $ptype (($sig->{params} // [])->@*) {
            $seen_free{$_} = 1 for $ptype->free_vars;
        }
        if ($sig->{returns}) {
            $seen_free{$_} = 1 for $sig->{returns}->free_vars;
        }

        # Check each free variable is declared
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

        # Validate effect annotations
        if ($sig->{effects}) {
            $self->_check_effect_wellformed($sig->{effects}, $fqn, \%declared);
        }

        # Validate bound expressions are well-formed
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

        # Validate that param/return type expressions are well-formed
        $self->_check_type_wellformed($_, $fqn) for ($sig->{params} // [])->@*;
        $self->_check_type_wellformed($sig->{returns}, $fqn) if $sig->{returns};

        # Kind well-formedness: verify type expressions respect declared kinds
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
    }
}

# ── Type Well-formedness ────────────────────────

sub _check_type_wellformed ($self, $type, $context) {
    return unless $type;

    my ($ctx_line, $ctx_file, $ctx_col) = $self->_fn_line($context);

    Typist::Type::Fold->walk($type, sub ($node) {
        if ($node->is_alias) {
            my $name = $node->alias_name;
            unless ($self->{registry}->has_alias($name) || $self->{registry}->has_typeclass($name)) {
                $self->{errors}->collect(
                    kind    => 'UnknownType',
                    message => "Type alias '$name' is not defined (in $context)",
                    file    => $ctx_file,
                    line    => $ctx_line,
                    col     => $ctx_col,
                );
            }
        }
    });
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

1;
