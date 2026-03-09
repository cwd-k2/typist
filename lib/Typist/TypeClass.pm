package Typist::TypeClass;
use v5.40;

our $VERSION = '0.01';

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
    require Typist::Parser;

    my $var_spec = $args{var} // 'T';
    my @decls = Typist::Parser->parse_param_decls($var_spec);

    my @var_names = map { $_->{name} } @decls;
    my @supers    = map { split /\s*\+\s*/, $_->{constraint_expr} }
                    grep { $_->{constraint_expr} } @decls;

    # Inherit var_kind from superclass when not explicitly annotated.
    # e.g., Applicative 'F: Functor' inherits * -> * from Functor's var_kind.
    my $registry = $args{registry};
    if ($registry && @supers) {
        for my $i (0 .. $#decls) {
            next if $decls[$i]{var_kind};
            for my $super (@supers) {
                my $super_def = $registry->lookup_typeclass($super) // next;
                my $super_kind = $super_def->var_kind;
                if ($super_kind) {
                    $decls[$i]{var_kind} = $super_kind;
                    last;
                }
            }
        }
    }

    # var_kinds: set only for multi-param or explicit kind annotation
    my @var_kinds;
    my $has_explicit_kind = grep { $_->{var_kind} } @decls;
    if ($has_explicit_kind || @decls > 1) {
        @var_kinds = map { $_->{var_kind} // Typist::Kind->Star() } @decls;
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
    no strict 'refs';
    for my $method_name (keys $self->{methods}->%*) {
        *{"${name}::${method_name}"} = sub {
            my @args = @_;
            if ($arity > 1) {
                # Multi-parameter: infer types from available arguments
                # (method arity may be less than typeclass arity)
                my $n = $#args < $arity - 1 ? $#args : $arity - 1;
                my @arg_types = map {
                    Typist::Inference->infer_value($args[$_])
                } 0 .. $n;
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
# $instance_index: optional { class => { type_expr => Inst } } for O(1) exact match.
sub resolve ($class_or_self, $class_name, $type_or_types, $instances, $instance_index = undef) {
    require Typist::Subtype;
    require Typist::Parser;

    my $insts = $instances->{$class_name} // return undef;
    my $idx   = $instance_index ? $instance_index->{$class_name} : undef;

    # Multi-parameter resolution: match each type against comma-split type_exprs
    # Supports prefix matching when fewer types than instance params
    # (e.g., convert(T)->U infers only T; U is determined by unique match)
    if (ref $type_or_types eq 'ARRAY') {
        my @types = @$type_or_types;

        # O(1) fast path: exact match by joined key
        if ($idx) {
            my $key = join(', ', map { $_->to_string } @types);
            if (my $hit = $idx->{$key}) {
                return $hit;
            }
        }

        my @candidates;
        for my $inst (@$insts) {
            my @inst_exprs = Typist::Parser->split_type_list($inst->type_expr);
            next unless @inst_exprs >= @types;
            my $match = 1;
            for my $i (0 .. $#types) {
                my $inst_type = Typist::Parser->parse($inst_exprs[$i]);
                unless ($types[$i]->equals($inst_type)
                     || Typist::Subtype->is_subtype($types[$i], $inst_type)) {
                    $match = 0;
                    last;
                }
            }
            push @candidates, $inst if $match;
        }
        return $candidates[0] if @candidates == 1;
        return $candidates[0] if @candidates > 1
            && @types == (Typist::Parser->split_type_list($candidates[0]->type_expr));
        return undef;
    }

    # Single-parameter resolution
    my $type = $type_or_types;

    # O(1) fast path: exact match by type name
    if ($idx) {
        my $key = $type->is_atom ? $type->name
                : $type->is_param ? $type->base
                : undef;
        if ($key && (my $hit = $idx->{$key})) {
            return $hit;
        }
    }

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
    Typist::Parser->split_type_list($self->{type_expr});
}

sub get_method ($self, $name) { $self->{methods}{$name} }

1;

=head1 NAME

Typist::TypeClass - Type class definitions and instances

=head1 SYNOPSIS

    use Typist::TypeClass;

    my $def = Typist::TypeClass->new_class(
        name    => 'Show',
        var     => 'T',
        methods => +{ show => '(T) -> Str' },
    );

    my $inst = Typist::TypeClass->new_instance(
        class     => 'Show',
        type_expr => 'Int',
        methods   => +{ show => sub ($x) { "$x" } },
    );

=head1 DESCRIPTION

Provides type class definitions (C<Def>) and instances (C<Inst>).
A type class defines an interface over one or more type variables;
instances supply concrete implementations for specific types.

Supports single-parameter classes (C<Show>), multi-parameter classes
(C<Convertible[T, U]>), superclass constraints (C<T: Eq>), and
higher-kinded type variables (C<F: * -E<gt> *>).

=head1 METHODS

=head2 new_class

    my $def = Typist::TypeClass->new_class(%args);

Creates a C<Typist::TypeClass::Def>. Required: C<name>. Optional:
C<var> (default C<"T">), C<methods>, C<supers>.

=head2 new_instance

    my $inst = Typist::TypeClass->new_instance(%args);

Creates a C<Typist::TypeClass::Inst>. Required: C<class>, C<type_expr>.
Optional: C<methods>.

=head1 Typist::TypeClass::Def

=head2 install_dispatch

    $def->install_dispatch($caller_package);

Installs runtime dispatch functions into the typeclass's own namespace
(C<${Class}::${method}>).  For example, C<< typeclass Show => ... >>
installs C<Show::show>.  The C<$caller_package> argument is accepted
for historical reasons but no longer affects the installation target.

Dispatch infers the argument type and resolves the matching
instance from the registry.

=head2 check_instance_completeness

    $def->check_instance_completeness($type_expr, %methods);

Dies if any required method is missing from the provided methods hash.

=head2 resolve

    my $inst = Typist::TypeClass::Def->resolve($class_name, $type, $instances, $instance_index);

Resolves an instance for the given type(s) from the instance list.
C<$type> may be a single Type object or an arrayref (multi-parameter).
Optional C<$instance_index> enables O(1) exact-match fast path before
falling back to linear subtype scan.

=head1 Typist::TypeClass::Inst

=head2 get_method

    my $coderef = $inst->get_method($method_name);

Returns the implementation coderef for the named method.

=head1 SEE ALSO

L<Typist>, L<Typist::Registry>, L<Typist::Inference>

=cut
