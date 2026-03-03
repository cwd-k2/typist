package Typist::Registry;
use v5.40;

our $VERSION = '0.01';

use Scalar::Util 'weaken';
use Typist::Parser;

# ── Default Instance ─────────────────────────────

my $DEFAULT;
sub _default ($class) { $DEFAULT //= $class->new }

# ── Constructor ──────────────────────────────────

sub new ($class, %args) {
    bless +{
        aliases   => +{},
        resolved  => +{},
        variables => +{},
        functions => +{},
        methods   => +{},
        packages  => +{},
        resolving  => +{},
        newtypes   => +{},
        typeclasses => +{},
        instances   => +{},
        datatypes   => +{},
        structs     => +{},
        effects     => +{},
        name_index  => +{},
    }, $class;
}

# ── Invocant Dispatch ────────────────────────────

sub _self ($invocant) {
    ref $invocant ? $invocant : $invocant->_default;
}

# ── Alias Management ────────────────────────────

sub define_alias ($invocant, $name, $expr) {
    my $self = _self($invocant);
    # Accept Type objects directly — store the string form for aliases, resolve immediately
    if (ref $expr && $expr->isa('Typist::Type')) {
        $self->{aliases}{$name}  = $expr->to_string;
        $self->{resolved}{$name} = $expr;
    } else {
        $self->{aliases}{$name} = $expr;
        delete $self->{resolved}{$name};
    }
}

sub lookup_type ($invocant, $name) {
    my $self = _self($invocant);
    return $self->{resolved}{$name} if exists $self->{resolved}{$name};

    # Newtypes, structs, and datatypes take precedence over aliases
    return $self->{newtypes}{$name}  if exists $self->{newtypes}{$name};
    return $self->{structs}{$name}   if exists $self->{structs}{$name};
    return $self->{datatypes}{$name} if exists $self->{datatypes}{$name};

    my $expr = $self->{aliases}{$name} // return undef;

    if ($self->{resolving}{$name}) {
        # Self-reference encountered — return a lazy Alias that will
        # resolve later, enabling productive recursion (through type
        # constructors like ArrayRef, Union, etc.)
        return Typist::Type::Alias->new($name);
    }

    $self->{resolving}{$name} = 1;
    my $type = eval {
        my $parsed = Typist::Parser->parse($expr);

        # Eagerly resolve if the parsed result is itself an alias
        if ($parsed->is_alias) {
            my $inner = $self->lookup_type($parsed->alias_name);
            if ($inner) {
                # Bare alias cycle (A -> B -> A): no type constructor intervenes
                if ($inner->is_alias && $inner->alias_name eq $name) {
                    die "Typist: alias cycle detected involving '$name'";
                }
                $parsed = $inner;
            }
        }

        $parsed;
    };
    my $err = $@;
    delete $self->{resolving}{$name};
    die $err if $err;

    $self->{resolved}{$name} = $type;
    $type;
}

sub has_alias ($invocant, $name) {
    my $self = _self($invocant);
    exists $self->{aliases}{$name} || exists $self->{newtypes}{$name} || exists $self->{structs}{$name} || exists $self->{datatypes}{$name};
}

# ── Newtype Management ─────────────────────────

sub register_newtype ($invocant, $name, $type_obj) {
    my $self = _self($invocant);
    $self->{newtypes}{$name} = $type_obj;
}

sub lookup_newtype ($invocant, $name) {
    my $self = _self($invocant);
    $self->{newtypes}{$name};
}

sub all_newtypes ($invocant) {
    my $self = _self($invocant);
    $self->{newtypes}->%*;
}

sub all_aliases ($invocant) {
    my $self = _self($invocant);
    $self->{aliases}->%*;
}

# ── Datatype Management ───────────────────────

sub register_datatype ($invocant, $name, $type_obj) {
    my $self = _self($invocant);
    $self->{datatypes}{$name} = $type_obj;
}

sub lookup_datatype ($invocant, $name) {
    my $self = _self($invocant);
    $self->{datatypes}{$name};
}

sub all_datatypes ($invocant) {
    my $self = _self($invocant);
    $self->{datatypes}->%*;
}

# ── Struct Management ──────────────────────────

sub register_type ($invocant, $name, $type_obj) {
    my $self = _self($invocant);
    $self->{structs}{$name} = $type_obj;
}

sub lookup_struct ($invocant, $name) {
    my $self = _self($invocant);
    $self->{structs}{$name};
}

sub all_structs ($invocant) {
    my $self = _self($invocant);
    $self->{structs}->%*;
}

# ── Variable Tracking ───────────────────────────

sub register_variable ($invocant, $info) {
    my $self = _self($invocant);
    my $key = $info->{ref} // die "register_variable requires ref";
    $self->{variables}{"$key"} = $info;
    weaken($self->{variables}{"$key"}{ref});
}

sub all_variables ($invocant) {
    my $self = _self($invocant);
    values $self->{variables}->%*;
}

sub _unregister_variable ($invocant, $key) {
    my $self = _self($invocant);
    delete $self->{variables}{$key};
}

# ── Function Tracking ───────────────────────────

sub register_function ($invocant, $pkg, $name, $sig) {
    my $self = _self($invocant);
    my $fqn = "${pkg}::${name}";
    $self->{functions}{$fqn} = $sig;
    push @{$self->{name_index}{$name} //= []}, $fqn;
}

sub lookup_function ($invocant, $pkg, $name) {
    my $self = _self($invocant);
    $self->{functions}{"${pkg}::${name}"};
}

sub unregister_function ($invocant, $pkg, $name) {
    my $self = _self($invocant);
    my $fqn = "${pkg}::${name}";
    delete $self->{functions}{$fqn};
    if (my $entries = $self->{name_index}{$name}) {
        @$entries = grep { $_ ne $fqn } @$entries;
        delete $self->{name_index}{$name} unless @$entries;
    }
}

sub all_functions ($invocant) {
    my $self = _self($invocant);
    $self->{functions}->%*;
}

# Search all packages for a function matching a bare name.
# Returns ($sig) or undef.  Uses name_index for O(1) lookup.
sub search_function_by_name ($invocant, $name) {
    my $self = _self($invocant);
    my $entries = $self->{name_index}{$name} // return undef;
    return undef unless @$entries;
    $self->{functions}{$entries->[0]};
}

# ── Method Tracking ─────────────────────────────

sub register_method ($invocant, $pkg, $name, $sig) {
    my $self = _self($invocant);
    $self->{methods}{"${pkg}::${name}"} = $sig;
}

sub lookup_method ($invocant, $pkg, $name) {
    my $self = _self($invocant);
    $self->{methods}{"${pkg}::${name}"};
}

sub all_methods ($invocant) {
    my $self = _self($invocant);
    $self->{methods}->%*;
}

# ── Package Tracking ────────────────────────────

sub register_package ($invocant, $pkg) {
    my $self = _self($invocant);
    $self->{packages}{$pkg} = 1;
}

sub all_packages ($invocant) {
    my $self = _self($invocant);
    keys $self->{packages}->%*;
}

# ── TypeClass Management ──────────────────────────

sub register_typeclass ($invocant, $name, $def) {
    my $self = _self($invocant);
    $self->{typeclasses}{$name} = $def;
}

sub has_typeclass ($invocant, $name) {
    my $self = _self($invocant);
    exists $self->{typeclasses}{$name};
}

sub lookup_typeclass ($invocant, $name) {
    my $self = _self($invocant);
    $self->{typeclasses}{$name};
}

sub all_typeclasses ($invocant) {
    my $self = _self($invocant);
    $self->{typeclasses}->%*;
}

sub register_instance ($invocant, $class_name, $type_expr, $inst) {
    my $self = _self($invocant);
    $self->{instances}{$class_name} //= [];
    push $self->{instances}{$class_name}->@*, $inst;
}

sub resolve_instance ($invocant, $class_name, $type_or_types) {
    my $self = _self($invocant);
    require Typist::TypeClass;
    Typist::TypeClass::Def->resolve($class_name, $type_or_types, $self->{instances});
}

sub unregister_instance ($invocant, $class_name, $type_expr) {
    my $self = _self($invocant);
    my $list = $self->{instances}{$class_name} // return;
    @$list = grep { $_->type_expr ne $type_expr } @$list;
    delete $self->{instances}{$class_name} unless @$list;
}

# ── Effect Management ────────────────────────────

sub register_effect ($invocant, $name, $effect) {
    my $self = _self($invocant);
    $self->{effects}{$name} = $effect;
}

sub lookup_effect ($invocant, $name) {
    my $self = _self($invocant);
    $self->{effects}{$name};
}

sub all_effects ($invocant) {
    my $self = _self($invocant);
    $self->{effects}->%*;
}

sub is_effect_label ($invocant, $name) {
    my $self = _self($invocant);
    exists $self->{effects}{$name};
}

# ── Merge ────────────────────────────────────────

sub merge ($self, $other) {
    for my $name (keys $other->{aliases}->%*) {
        $self->{aliases}{$name} //= $other->{aliases}{$name};
    }
    for my $fqn (keys $other->{functions}->%*) {
        unless (exists $self->{functions}{$fqn}) {
            $self->{functions}{$fqn} = $other->{functions}{$fqn};
            my ($name) = $fqn =~ /::(\w+)\z/;
            push @{$self->{name_index}{$name} //= []}, $fqn if $name;
        }
    }
    for my $fqn (keys $other->{methods}->%*) {
        $self->{methods}{$fqn} //= $other->{methods}{$fqn};
    }
    for my $name (keys $other->{effects}->%*) {
        $self->{effects}{$name} //= $other->{effects}{$name};
    }
    for my $name (keys $other->{newtypes}->%*) {
        $self->{newtypes}{$name} //= $other->{newtypes}{$name};
    }
    for my $name (keys $other->{datatypes}->%*) {
        $self->{datatypes}{$name} //= $other->{datatypes}{$name};
    }
    for my $name (keys(($other->{structs} // +{})->%*)) {
        $self->{structs}{$name} //= $other->{structs}{$name};
    }
    for my $name (keys $other->{typeclasses}->%*) {
        $self->{typeclasses}{$name} //= $other->{typeclasses}{$name};
    }
    for my $class_name (keys $other->{instances}->%*) {
        $self->{instances}{$class_name} //= [];
        push $self->{instances}{$class_name}->@*, $other->{instances}{$class_name}->@*;
    }
    # Clear resolved cache since new aliases may change resolution
    $self->{resolved} = +{};
    $self;
}

# ── Utility ─────────────────────────────────────

sub reset ($invocant) {
    if (ref $invocant) {
        $invocant->{aliases}   = +{};
        $invocant->{resolved}  = +{};
        $invocant->{variables} = +{};
        $invocant->{functions} = +{};
        $invocant->{methods}   = +{};
        $invocant->{packages}  = +{};
        $invocant->{resolving} = +{};
        $invocant->{newtypes}   = +{};
        $invocant->{datatypes}  = +{};
        $invocant->{typeclasses} = +{};
        $invocant->{instances}   = +{};
        $invocant->{effects}     = +{};
        $invocant->{name_index}  = +{};
    } else {
        $DEFAULT = undef;
    }
}

# ── Exported typedef ────────────────────────────

sub typedef ($name, $expr) {
    require Typist::Type;
    __PACKAGE__->define_alias($name, Typist::Type->coerce($expr));
}

1;

__END__

=head1 NAME

Typist::Registry - Type, function, and effect registration store

=head1 SYNOPSIS

    use Typist::Registry;

    # Class-level (singleton) usage
    Typist::Registry->define_alias('Name', 'Str');
    my $type = Typist::Registry->lookup_type('Name');
    Typist::Registry->register_function('main', 'add', $sig);

    # Instance-level usage (for LSP workspace isolation)
    my $reg = Typist::Registry->new;
    $reg->define_alias('Price', 'Int');
    $reg->register_newtype('UserId', $newtype_obj);

=head1 DESCRIPTION

Typist::Registry is the central store for type aliases, newtypes,
datatypes, functions, methods, effects, typeclasses, and instances.
It supports both class-level (singleton) and instance-level usage
through invocant dispatch: class method calls operate on a shared
default instance, while object method calls operate on the receiver.

Alias resolution is lazy with cycle detection. Newtypes and datatypes
take precedence over aliases during lookup. The resolution cache is
cleared on merge to accommodate new definitions.

=head1 CONSTRUCTOR

=head2 new

    my $reg = Typist::Registry->new;

Create a fresh registry instance. All internal stores are initialized
to empty hashes.

=head1 ALIAS MANAGEMENT

=head2 define_alias

    $reg->define_alias($name, $expr);

Register a type alias. Accepts both type expression strings and
L<Typist::Type> objects.

=head2 lookup_type

    my $type = $reg->lookup_type($name);

Resolve a type alias by name. Handles recursive aliases through
lazy resolution with cycle detection. Returns a type object or C<undef>.

=head2 has_alias

    my $bool = $reg->has_alias($name);

Returns true if the name is registered as an alias, newtype, or datatype.

=head2 all_aliases

    my %aliases = $reg->all_aliases;

Returns all raw alias definitions as name-expression pairs.

=head1 NEWTYPE MANAGEMENT

=head2 register_newtype / lookup_newtype / all_newtypes

Register, look up, or list all nominal types.

=head1 DATATYPE MANAGEMENT

=head2 register_datatype / lookup_datatype / all_datatypes

Register, look up, or list all algebraic data types.

=head1 FUNCTION TRACKING

=head2 register_function

    $reg->register_function($package, $name, $signature);

Register a function signature. The signature is a hashref with C<params>,
C<returns>, C<generics>, and C<effects> keys.

=head2 lookup_function

    my $sig = $reg->lookup_function($package, $name);

Look up a function signature by package and name.

=head2 search_function_by_name

    my $sig = $reg->search_function_by_name($name);

Search all packages for a function matching the given bare name.
Used for cross-package resolution of imported or constructor functions.

=head2 all_functions

    my %fns = $reg->all_functions;

Returns all registered function signatures keyed by qualified name.

=head1 METHOD TRACKING

=head2 register_method / lookup_method / all_methods

Register, look up, or list all method signatures. Methods are stored
separately from functions for C<$self-E<gt>method()> resolution.

=head1 TYPECLASS MANAGEMENT

=head2 register_typeclass / lookup_typeclass / has_typeclass / all_typeclasses

Register, look up, check existence, or list all typeclass definitions.

=head2 register_instance / resolve_instance

Register a typeclass instance or resolve an instance by class name and
type expression.

=head1 EFFECT MANAGEMENT

=head2 register_effect / lookup_effect / all_effects / is_effect_label

Register, look up, list, or check existence of effect definitions.

=head1 UTILITY

=head2 merge

    $reg->merge($other_registry);

Merge another registry's contents into this one. Existing entries are
not overwritten. Clears the resolution cache.

=head2 reset

    $reg->reset;

Clear all stored definitions. On instances, resets all hashes. On the
class, resets the default singleton.

=head1 SEE ALSO

L<Typist>, L<Typist::Parser>, L<Typist::LSP::Workspace>

=cut
