package Typist::TypeClass;
use v5.40;

# Type class definition and instance structures.
#
# A type class defines an interface:
#   { name => 'Eq', var => 'T', methods => { eq => sig, neq => sig }, supers => [] }
#
# An instance provides implementations for a specific type:
#   { class => 'Eq', type_expr => 'Int', methods => { eq => coderef, neq => coderef } }

sub new_class ($class, %args) {
    my $var_spec = $args{var} // 'T';
    my ($var_name, $var_kind_str);

    # Parse "F: * -> *" syntax for HKT
    if ($var_spec =~ /\A(\w+)\s*:\s*(.+)\z/) {
        $var_name     = $1;
        $var_kind_str = $2;
    } else {
        $var_name     = $var_spec;
        $var_kind_str = undef;
    }

    bless +{
        name         => ($args{name}    // die("TypeClass requires name\n")),
        var          => $var_name,
        var_kind_str => $var_kind_str,
        methods      => ($args{methods} // +{}),
        supers       => ($args{supers}  // []),
    }, "${class}::Def";
}

sub new_instance ($class, %args) {
    bless +{
        class     => ($args{class}     // die("Instance requires class\n")),
        type_expr => ($args{type_expr} // die("Instance requires type_expr\n")),
        methods   => ($args{methods}   // +{}),
    }, "${class}::Inst";
}

# ── Class Definition ─────────────────────────────

package Typist::TypeClass::Def;
use v5.40;

sub name         ($self) { $self->{name} }
sub var          ($self) { $self->{var} }
sub var_kind_str ($self) { $self->{var_kind_str} }
sub methods      ($self) { $self->{methods}->%* }
sub supers       ($self) { $self->{supers}->@* }

sub method_names ($self) { sort keys $self->{methods}->%* }

# Install dispatch functions into namespace for runtime instance resolution.
sub install_dispatch ($self, $caller) {
    require Typist::Inference;
    require Typist::Registry;

    my $name = $self->{name};
    my $ns = "Typist::TC::${name}";
    no strict 'refs';
    for my $method_name (keys $self->{methods}->%*) {
        *{"${ns}::${method_name}"} = sub {
            my @args = @_;
            my $arg_type = Typist::Inference->infer_value($args[0]);
            my $inst = Typist::Registry->resolve_instance($name, $arg_type)
                // die "Typist: no instance of $name for " . $arg_type->to_string . "\n";
            my $impl = $inst->get_method($method_name)
                // die "Typist: instance $name for " . $inst->type_expr
                     . " missing method $method_name\n";
            $impl->(@args);
        };
        *{"${caller}::${name}::${method_name}"} = \&{"${ns}::${method_name}"};
    }
}

# Verify that an instance provides all required methods.
sub check_instance_completeness ($self, $type_expr, %methods) {
    for my $required ($self->method_names) {
        die "Typist: instance $self->{name} for $type_expr missing method '$required'\n"
            unless exists $methods{$required};
    }
}

# Resolve instance for a given type from instance list.
sub resolve ($class_or_self, $class_name, $type, $instances) {
    require Typist::Subtype;
    require Typist::Parser;

    my $insts = $instances->{$class_name} // return undef;

    for my $inst (@$insts) {
        my $type_expr = $inst->type_expr;

        # HKT: match by constructor name (e.g., "ArrayRef" matches ArrayRef[T])
        if ($type->is_param && $type_expr eq $type->base) {
            return $inst;
        }

        my $inst_type = Typist::Parser->parse($type_expr);
        if ($type->equals($inst_type)
            || Typist::Subtype->is_subtype($type, $inst_type)) {
            return $inst;
        }
    }
    undef;
}

# ── Instance ─────────────────────────────────────

package Typist::TypeClass::Inst;
use v5.40;

sub class     ($self) { $self->{class} }
sub type_expr ($self) { $self->{type_expr} }
sub methods   ($self) { $self->{methods}->%* }

sub get_method ($self, $name) { $self->{methods}{$name} }

1;
