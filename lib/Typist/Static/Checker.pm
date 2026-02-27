package Typist::Static::Checker;
use v5.40;

use Typist::Registry;
use Typist::Parser;
use Typist::Error;
use Typist::Error::Global;
use Typist::Kind;
use Typist::KindChecker;

# ── Constructor ──────────────────────────────────

sub new ($class, %args) {
    bless +{
        registry => $args{registry} // 'Typist::Registry',
        errors   => $args{errors}   // 'Typist::Error::Global',
    }, $class;
}

# ── CHECK-phase Static Analysis ─────────────────

sub analyze ($self) {
    $self->_check_aliases;
    $self->_check_functions;
}

# ── Alias Validation ────────────────────────────

# Verify all aliases resolve without cycles.
sub _check_aliases ($self) {
    my %aliases = $self->{registry}->all_aliases;

    for my $name (sort keys %aliases) {
        my $type = eval { $self->{registry}->lookup_type($name) };
        if ($@) {
            if ($@ =~ /cycle/) {
                $self->{errors}->collect(
                    kind    => 'CycleError',
                    message => "Alias cycle detected involving '$name'",
                    file    => '(alias definition)',
                    line    => 0,
                );
            } else {
                $self->{errors}->collect(
                    kind    => 'ResolveError',
                    message => "Failed to resolve alias '$name': $@",
                    file    => '(alias definition)',
                    line    => 0,
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
                    message => "Type variable '$var' in $fqn is not declared in :Generic",
                    file    => '(function signature)',
                    line    => 0,
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
                    file    => '(function signature)',
                    line    => 0,
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
                        file    => '(function signature)',
                        line    => 0,
                    );
                }
            }
            if ($sig->{returns}) {
                eval { Typist::KindChecker->infer_kind($sig->{returns}, \%var_kinds) };
                if ($@) {
                    $self->{errors}->collect(
                        kind    => 'KindError',
                        message => "Kind error in return type of $fqn: $@",
                        file    => '(function signature)',
                        line    => 0,
                    );
                }
            }
        }
    }
}

# ── Type Well-formedness ────────────────────────

sub _check_type_wellformed ($self, $type, $context) {
    return unless $type;

    if ($type->is_alias) {
        unless ($self->{registry}->has_alias($type->alias_name)) {
            $self->{errors}->collect(
                kind    => 'UnknownType',
                message => "Type alias '" . $type->alias_name . "' is not defined (in $context)",
                file    => '(type expression)',
                line    => 0,
            );
        }
    }

    if ($type->is_param) {
        $self->_check_type_wellformed($_, $context) for $type->params;
    }
    if ($type->is_union) {
        $self->_check_type_wellformed($_, $context) for $type->members;
    }
    if ($type->is_intersection) {
        $self->_check_type_wellformed($_, $context) for $type->members;
    }
    if ($type->is_func) {
        $self->_check_type_wellformed($_, $context) for $type->params;
        $self->_check_type_wellformed($type->returns, $context);
    }
    if ($type->is_struct) {
        my %r = $type->required_fields;
        my %o = $type->optional_fields;
        $self->_check_type_wellformed($_, $context) for values %r, values %o;
    }

    if ($type->is_eff) {
        $self->_check_type_wellformed($type->row, $context);
    }
}

# ── Effect Well-formedness ────────────────────────

sub _check_effect_wellformed ($self, $eff, $context, $declared_vars) {
    my $row = $eff->is_eff ? $eff->row : $eff;
    return unless $row->is_row;

    # Check labels are registered effects
    for my $label ($row->labels) {
        unless ($self->{registry}->is_effect_label($label)) {
            $self->{errors}->collect(
                kind    => 'UnknownEffect',
                message => "Effect '$label' is not defined (in $context)",
                file    => '(effect annotation)',
                line    => 0,
            );
        }
    }

    # Check row variable is declared in :Generic
    if (defined $row->row_var) {
        unless ($declared_vars->{$row->row_var}) {
            $self->{errors}->collect(
                kind    => 'UndeclaredRowVar',
                message => "Row variable '" . $row->row_var . "' in $context is not declared in :Generic",
                file    => '(effect annotation)',
                line    => 0,
            );
        }
    }
}

1;
