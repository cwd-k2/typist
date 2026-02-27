package Typist::Checker;
use v5.40;

use Typist::Registry;
use Typist::Parser;
use Typist::Error;

# ── Constructor ──────────────────────────────────

sub new ($class, %args) {
    bless {
        registry => $args{registry} // 'Typist::Registry',
        errors   => $args{errors}   // 'Typist::Error',
    }, $class;
}

# ── CHECK-phase Static Analysis ─────────────────

sub analyze ($self) {
    $self->{errors}->reset;

    $self->_check_aliases;
    $self->_check_functions;

    if ($self->{errors}->has_errors) {
        warn $self->{errors}->report;
    }
}

# ── Alias Validation ────────────────────────────

# Verify all aliases resolve without cycles.
sub _check_aliases ($self) {
    my %aliases = $self->{registry}->all_aliases;

    for my $name (sort keys %aliases) {
        eval { $self->{registry}->lookup_type($name) };
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
        my %declared = map { $_ => 1 } ($sig->{generics} // [])->@*;

        # Collect all free type variables from params and returns
        my @free;
        for my $ptype (($sig->{params} // [])->@*) {
            push @free, $ptype->free_vars;
        }
        if ($sig->{returns}) {
            push @free, $sig->{returns}->free_vars;
        }

        # Check each free variable is declared
        for my $var (@free) {
            unless ($declared{$var}) {
                $self->{errors}->collect(
                    kind    => 'UndeclaredTypeVar',
                    message => "Type variable '$var' in $fqn is not declared in :Generic",
                    file    => '(function signature)',
                    line    => 0,
                );
            }
        }

        # Validate that param/return type expressions are well-formed
        $self->_check_type_wellformed($_, $fqn) for ($sig->{params} // [])->@*;
        $self->_check_type_wellformed($sig->{returns}, $fqn) if $sig->{returns};
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
        my %f = $type->fields;
        $self->_check_type_wellformed($_, $context) for values %f;
    }
}

1;
