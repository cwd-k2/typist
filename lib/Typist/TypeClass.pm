package Typist::TypeClass;
use v5.40;

# Type class definition and instance structures.
#
# A type class defines an interface (single or multi-parameter):
#   Single: { name => 'Eq', var_names => ['T'], methods => { eq => sig }, supers => [] }
#   Multi:  { name => 'Convertible', var_names => ['T','U'], methods => { convert => sig } }
#
# An instance provides implementations for specific type(s):
#   Single: { class => 'Eq', type_expr => 'Int', methods => { eq => coderef } }
#   Multi:  { class => 'Convertible', type_expr => 'Int, Str', methods => { convert => coderef } }

sub new_class ($class, %args) {
    require Typist::Kind;

    my $var_spec = $args{var} // 'T';
    my (@var_names, @var_kinds, @supers);

    # Multi-parameter: "T, U" — comma-separated plain variables
    if ($var_spec =~ /,/) {
        @var_names = map { s/\A\s+//r =~ s/\s+\z//r } split /,/, $var_spec;
        @var_kinds = map { Typist::Kind->Star() } @var_names;
    }
    # Single parameter: "T", "T: Eq", "F: * -> *"
    elsif ($var_spec =~ /\A(\w+)\s*:\s*(.+)\z/) {
        my ($vn, $constraint) = ($1, $2);
        if ($constraint =~ /\A[\s\*\-\>]+\z/) {
            # HKT kind syntax: "F: * -> *"
            @var_names = ($vn);
            @var_kinds = (Typist::Kind->parse($constraint));
        } else {
            # Superclass constraint: "T: Eq" or "T: Show + Eq"
            @var_names = ($vn);
            @supers    = split /\s*\+\s*/, $constraint;
        }
    } else {
        @var_names = ($var_spec);
    }

    bless +{
        name      => ($args{name}    // die("TypeClass requires name\n")),
        var_names => \@var_names,
        var_kinds => (@var_kinds ? \@var_kinds : undef),
        methods   => ($args{methods} // +{}),
        supers    => ($args{supers}  // \@supers),
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

sub name     ($self) { $self->{name} }
sub methods  ($self) { $self->{methods}->%* }
sub supers   ($self) { $self->{supers}->@* }

# Backward-compatible: returns the first (or only) variable name.
sub var ($self) { $self->{var_names}[0] }

# Returns list of all type variable names.
sub var_names ($self) { $self->{var_names}->@* }

# Returns the number of type parameters.
sub arity ($self) { scalar $self->{var_names}->@* }

# True if this is a multi-parameter type class.
sub is_multi_param ($self) { $self->{var_names}->@* > 1 }

# Backward-compatible: returns the first kind, or undef.
sub var_kind ($self) {
    $self->{var_kinds} ? $self->{var_kinds}[0] : undef;
}

# Compatibility: returns the kind as a string, or undef.
sub var_kind_str ($self) {
    my $k = $self->var_kind;
    $k ? $k->to_string : undef;
}

sub method_names ($self) { sort keys $self->{methods}->%* }

# Install dispatch functions into namespace for runtime instance resolution.
sub install_dispatch ($self, $caller) {
    require Typist::Inference;
    require Typist::Registry;

    my $name  = $self->{name};
    my $arity = $self->arity;
    my $ns    = "Typist::TC::${name}";
    no strict 'refs';
    for my $method_name (keys $self->{methods}->%*) {
        *{"${ns}::${method_name}"} = sub {
            my @args = @_;
            if ($arity > 1) {
                # Multi-parameter: infer types from first N arguments
                my @arg_types = map {
                    Typist::Inference->infer_value($args[$_])
                } 0 .. ($arity - 1);
                my $inst = Typist::Registry->resolve_instance($name, \@arg_types)
                    // die "Typist: no instance of $name for ("
                         . join(', ', map { $_->to_string } @arg_types) . ")\n";
                my $impl = $inst->get_method($method_name)
                    // die "Typist: instance $name for " . $inst->type_expr
                         . " missing method $method_name\n";
                $impl->(@args);
            } else {
                # Single-parameter: infer type from first argument
                my $arg_type = Typist::Inference->infer_value($args[0]);
                my $inst = Typist::Registry->resolve_instance($name, $arg_type)
                    // die "Typist: no instance of $name for " . $arg_type->to_string . "\n";
                my $impl = $inst->get_method($method_name)
                    // die "Typist: instance $name for " . $inst->type_expr
                         . " missing method $method_name\n";
                $impl->(@args);
            }
        };
        *{"${caller}::${name}::${method_name}"} = \&{"${ns}::${method_name}"};
    }
}

# Verify that superclass instances exist for the given type.
# (Superclass checking applies to single-parameter type classes.)
sub check_superclass_instances ($self, $type_expr, $registry) {
    return if $self->is_multi_param;
    for my $super ($self->supers) {
        my $type = Typist::Parser->parse($type_expr);
        my $resolved = $registry->resolve_instance($super, $type);
        die "Typist: instance $self->{name} for $type_expr requires "
          . "superclass instance $super for $type_expr\n"
            unless $resolved;
    }
}

# Verify that an instance provides all required methods.
sub check_instance_completeness ($self, $type_expr, %methods) {
    for my $required ($self->method_names) {
        die "Typist: instance $self->{name} for $type_expr missing method '$required'\n"
            unless exists $methods{$required};
    }
}

# Resolve instance for given type(s) from instance list.
# $type_or_types: a single Type object, or an arrayref of Type objects (multi-param).
sub resolve ($class_or_self, $class_name, $type_or_types, $instances) {
    require Typist::Subtype;
    require Typist::Parser;

    my $insts = $instances->{$class_name} // return undef;

    # Multi-parameter resolution: match each type against comma-split type_exprs
    if (ref $type_or_types eq 'ARRAY') {
        my @types = @$type_or_types;
        for my $inst (@$insts) {
            my @inst_exprs = map { s/\A\s+//r =~ s/\s+\z//r }
                             split /,/, $inst->type_expr;
            next unless @inst_exprs == @types;
            my $match = 1;
            for my $i (0 .. $#types) {
                my $inst_type = Typist::Parser->parse($inst_exprs[$i]);
                unless ($types[$i]->equals($inst_type)
                     || Typist::Subtype->is_subtype($types[$i], $inst_type)) {
                    $match = 0;
                    last;
                }
            }
            return $inst if $match;
        }
        return undef;
    }

    # Single-parameter resolution (existing behavior)
    my $type = $type_or_types;
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

# Returns list of individual type expressions (for multi-parameter instances).
sub type_exprs ($self) {
    map { s/\A\s+//r =~ s/\s+\z//r } split /,/, $self->{type_expr};
}

sub get_method ($self, $name) { $self->{methods}{$name} }

1;
