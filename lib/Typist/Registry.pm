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
        aliases        => +{},
        resolved       => +{},
        variables      => +{},
        functions      => +{},
        methods        => +{},
        packages       => +{},
        resolving      => +{},
        newtypes       => +{},
        typeclasses    => +{},
        instances      => +{},
        datatypes      => +{},
        structs        => +{},
        effects        => +{},
        name_index     => +{},
        instance_index => +{},
        defined_in     => +{},
        package_uses   => +{},
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
    exists $self->{aliases}{$name}
        || exists $self->{newtypes}{$name}
        || exists $self->{structs}{$name}
        || exists $self->{datatypes}{$name};
}

sub unregister_alias ($invocant, $name) {
    my $self = _self($invocant);
    delete $self->{aliases}{$name};
    delete $self->{resolved}{$name};
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

sub unregister_newtype ($invocant, $name) {
    my $self = _self($invocant);
    delete $self->{newtypes}{$name};
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

sub unregister_datatype ($invocant, $name) {
    my $self = _self($invocant);
    delete $self->{datatypes}{$name};
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

sub unregister_type ($invocant, $name) {
    my $self = _self($invocant);
    delete $self->{structs}{$name};
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

sub unregister_method ($invocant, $pkg, $name) {
    my $self = _self($invocant);
    delete $self->{methods}{"${pkg}::${name}"};
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

# ── Type Provenance ────────────────────────────────
# Track which package defined each type name.

sub set_defined_in ($invocant, $name, $pkg) {
    my $self = _self($invocant);
    $self->{defined_in}{$name} = $pkg;
}

sub defined_in ($invocant, $name) {
    my $self = _self($invocant);
    $self->{defined_in}{$name};
}

sub types_defined_by ($invocant, $pkg) {
    my $self = _self($invocant);
    grep { ($self->{defined_in}{$_} // '') eq $pkg } keys $self->{defined_in}->%*;
}

# ── Package Dependency Tracking ───────────────────
# Record that $pkg uses $used_pkg (via `use`).

sub register_package_use ($invocant, $pkg, $used_pkg) {
    my $self = _self($invocant);
    push @{$self->{package_uses}{$pkg} //= []}, $used_pkg;
}

sub package_uses ($invocant, $pkg) {
    my $self = _self($invocant);
    @{$self->{package_uses}{$pkg} // []};
}

# Check if type $name is visible to $pkg:
# - defined in $pkg itself
# - defined in a package that $pkg uses (directly)
# - has no provenance (prelude / builtin)
sub is_type_visible ($invocant, $name, $pkg) {
    my $self = _self($invocant);
    my $definer = $self->{defined_in}{$name};
    return 1 unless defined $definer;    # no provenance → always visible (builtins)
    return 1 if $definer eq $pkg;        # defined locally
    for my $used ($self->package_uses($pkg)) {
        return 1 if $definer eq $used;
    }
    0;
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

sub unregister_typeclass ($invocant, $name) {
    my $self = _self($invocant);
    delete $self->{typeclasses}{$name};
}

sub register_instance ($invocant, $class_name, $type_expr, $inst) {
    my $self = _self($invocant);
    $self->{instances}{$class_name} //= [];
    push $self->{instances}{$class_name}->@*, $inst;
    $self->{instance_index}{$class_name}{$type_expr} //= $inst;
}

sub resolve_instance ($invocant, $class_name, $type_or_types) {
    my $self = _self($invocant);
    require Typist::TypeClass;
    Typist::TypeClass::Def->resolve($class_name, $type_or_types, $self->{instances}, $self->{instance_index});
}

sub unregister_instance ($invocant, $class_name, $type_expr) {
    my $self = _self($invocant);
    my $list = $self->{instances}{$class_name} // return;
    @$list = grep { $_->type_expr ne $type_expr } @$list;
    delete $self->{instances}{$class_name} unless @$list;
    delete $self->{instance_index}{$class_name}{$type_expr};
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

sub unregister_effect ($invocant, $name) {
    my $self = _self($invocant);
    delete $self->{effects}{$name};
}

sub is_effect_label ($invocant, $name) {
    my $self = _self($invocant);
    exists $self->{effects}{$name};
}

sub is_ambient_effect ($invocant, $name) {
    my $self = _self($invocant);
    my $eff = $self->{effects}{$name} // return 0;
    $eff->is_ambient;
}

# ── Merge ────────────────────────────────────────

sub merge ($self, $other) {
    # Simple stores: first-write-wins
    for my $store (qw(aliases methods effects newtypes datatypes structs typeclasses defined_in)) {
        for my $name (keys(($other->{$store} // +{})->%*)) {
            $self->{$store}{$name} //= $other->{$store}{$name};
        }
    }

    # Functions: also update name_index
    for my $fqn (keys $other->{functions}->%*) {
        unless (exists $self->{functions}{$fqn}) {
            $self->{functions}{$fqn} = $other->{functions}{$fqn};
            my ($name) = $fqn =~ /::(\w+)\z/;
            push @{$self->{name_index}{$name} //= []}, $fqn if $name;
        }
    }

    # Instances: accumulate arrays and index entries
    for my $class_name (keys $other->{instances}->%*) {
        $self->{instances}{$class_name} //= [];
        push $self->{instances}{$class_name}->@*, $other->{instances}{$class_name}->@*;
        if (my $idx = $other->{instance_index}{$class_name}) {
            for my $te (keys %$idx) {
                $self->{instance_index}{$class_name}{$te} //= $idx->{$te};
            }
        }
    }

    # Package uses: accumulate arrays
    for my $pkg (keys(($other->{package_uses} // +{})->%*)) {
        my $uses = $other->{package_uses}{$pkg} // [];
        push @{$self->{package_uses}{$pkg} //= []}, @$uses;
    }

    # Clear resolved cache since new aliases may change resolution
    $self->{resolved} = +{};
    $self;
}

# ── Utility ─────────────────────────────────────

sub reset ($invocant) {
    if (ref $invocant) {
        $invocant->{$_} = +{} for qw(
            aliases   resolved    variables  functions
            methods   packages    resolving  newtypes
            datatypes typeclasses instances  effects
            name_index instance_index defined_in package_uses
        );
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
datatypes, structs, functions, methods, effects, typeclasses, and
instances. It supports both class-level (singleton) and instance-level
usage through invocant dispatch: class method calls operate on a shared
default instance, while object method calls operate on the receiver.

Alias resolution is lazy with cycle detection. Newtypes, structs, and
datatypes take precedence over aliases during lookup. The resolution
cache is cleared on merge to accommodate new definitions.

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

Resolve a type name by looking up newtypes, structs, and datatypes
first, then aliases. Handles recursive aliases through lazy resolution
with cycle detection. Returns a type object or C<undef>.

=head2 has_alias

    my $bool = $reg->has_alias($name);

Returns true if the name is registered as an alias, newtype, struct,
or datatype.

=head2 all_aliases

    my %aliases = $reg->all_aliases;

Returns all raw alias definitions as name-expression pairs.

=head2 unregister_alias

    $reg->unregister_alias($name);

Remove a type alias and its resolved cache entry.

=head1 NEWTYPE MANAGEMENT

=head2 register_newtype

    $reg->register_newtype($name, $type_obj);

Register a nominal newtype under the given name.

=head2 lookup_newtype

    my $type = $reg->lookup_newtype($name);

Look up a newtype by name. Returns the type object or C<undef>.

=head2 all_newtypes

    my %newtypes = $reg->all_newtypes;

Returns all registered newtypes as name-type pairs.

=head2 unregister_newtype

    $reg->unregister_newtype($name);

Remove a newtype registration.

=head1 DATATYPE MANAGEMENT

=head2 register_datatype

    $reg->register_datatype($name, $type_obj);

Register an algebraic data type (tagged union) under the given name.

=head2 lookup_datatype

    my $type = $reg->lookup_datatype($name);

Look up a datatype by name. Returns the L<Typist::Type::Data> object
or C<undef>.

=head2 all_datatypes

    my %datatypes = $reg->all_datatypes;

Returns all registered datatypes as name-type pairs.

=head2 unregister_datatype

    $reg->unregister_datatype($name);

Remove a datatype registration.

=head1 STRUCT MANAGEMENT

=head2 register_type

    $reg->register_type($name, $type_obj);

Register a struct type under the given name.

=head2 lookup_struct

    my $type = $reg->lookup_struct($name);

Look up a struct by name. Returns the type object or C<undef>.

=head2 all_structs

    my %structs = $reg->all_structs;

Returns all registered structs as name-type pairs.

=head2 unregister_type

    $reg->unregister_type($name);

Remove a struct registration.

=head1 VARIABLE TRACKING

=head2 register_variable

    $reg->register_variable(+{ ref => \$var, type => $type, name => '$x' });

Register a typed variable. The info hashref must contain a C<ref> key.
The reference is weakened to avoid preventing garbage collection.

=head2 all_variables

    my @vars = $reg->all_variables;

Returns all registered variable info hashrefs.

=head1 FUNCTION TRACKING

=head2 register_function

    $reg->register_function($package, $name, $signature);

Register a function signature and update the C<name_index> for O(1)
bare-name lookup. The signature is a hashref with C<params>, C<returns>,
C<generics>, and C<effects> keys.

=head2 lookup_function

    my $sig = $reg->lookup_function($package, $name);

Look up a function signature by package and name.

=head2 search_function_by_name

    my $sig = $reg->search_function_by_name($name);

Search all packages for a function matching the given bare name.
Uses C<name_index> for O(1) lookup. Returns the first match or C<undef>.

=head2 all_functions

    my %fns = $reg->all_functions;

Returns all registered function signatures keyed by qualified name.

=head2 unregister_function

    $reg->unregister_function($package, $name);

Remove a function registration and its C<name_index> entry.

=head1 METHOD TRACKING

=head2 register_method

    $reg->register_method($package, $name, $signature);

Register a method signature. Methods are stored separately from
functions for C<< $self->method() >> resolution.

=head2 lookup_method

    my $sig = $reg->lookup_method($package, $name);

Look up a method signature by package and name.

=head2 all_methods

    my %methods = $reg->all_methods;

Returns all registered method signatures keyed by qualified name.

=head2 unregister_method

    $reg->unregister_method($package, $name);

Remove a method registration.

=head1 PACKAGE TRACKING

=head2 register_package

    $reg->register_package($package);

Record that a package has been seen during analysis.

=head2 all_packages

    my @pkgs = $reg->all_packages;

Returns the names of all registered packages.

=head1 TYPECLASS MANAGEMENT

=head2 register_typeclass

    $reg->register_typeclass($name, $def);

Register a typeclass definition (L<Typist::TypeClass::Def>).

=head2 lookup_typeclass

    my $def = $reg->lookup_typeclass($name);

Look up a typeclass definition by name. Returns the definition or
C<undef>.

=head2 has_typeclass

    my $bool = $reg->has_typeclass($name);

Returns true if a typeclass with the given name is registered.

=head2 all_typeclasses

    my %tcs = $reg->all_typeclasses;

Returns all registered typeclass definitions as name-definition pairs.

=head2 unregister_typeclass

    $reg->unregister_typeclass($name);

Remove a typeclass registration.

=head2 register_instance

    $reg->register_instance($class_name, $type_expr, $inst);

Register a typeclass instance for the given class and type expression.

=head2 resolve_instance

    my $inst = $reg->resolve_instance($class_name, $type_or_types);

Resolve a typeclass instance by class name and concrete type. Delegates
to L<Typist::TypeClass::Def/resolve>.

=head2 unregister_instance

    $reg->unregister_instance($class_name, $type_expr);

Remove a typeclass instance matching the given class name and type
expression.

=head1 EFFECT MANAGEMENT

=head2 register_effect

    $reg->register_effect($name, $effect);

Register an effect definition under the given label.

=head2 lookup_effect

    my $effect = $reg->lookup_effect($name);

Look up an effect by label name. Returns the effect object or C<undef>.

=head2 all_effects

    my %effects = $reg->all_effects;

Returns all registered effects as name-effect pairs.

=head2 unregister_effect

    $reg->unregister_effect($name);

Remove an effect registration.

=head2 is_effect_label

    my $bool = $reg->is_effect_label($name);

Returns true if the given name is a registered effect label.

=head1 UTILITY

=head2 merge

    $reg->merge($other_registry);

Merge another registry's contents into this one. Existing entries are
not overwritten. Clears the resolution cache.

=head2 reset

    $reg->reset;

Clear all stored definitions. On instances, resets all hashes. On the
class, resets the default singleton.

=head2 typedef

    Typist::Registry::typedef($name, $expr);

Convenience function that coerces C<$expr> via L<Typist::Type/coerce>
and registers it as an alias on the singleton registry.

=head1 SEE ALSO

L<Typist>, L<Typist::Parser>, L<Typist::LSP::Workspace>

=cut
