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
        effects     => +{},
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

    # Newtypes and datatypes take precedence over aliases
    return $self->{newtypes}{$name}  if exists $self->{newtypes}{$name};
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
    exists $self->{aliases}{$name} || exists $self->{newtypes}{$name} || exists $self->{datatypes}{$name};
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
    $self->{functions}{"${pkg}::${name}"} = $sig;
}

sub lookup_function ($invocant, $pkg, $name) {
    my $self = _self($invocant);
    $self->{functions}{"${pkg}::${name}"};
}

sub all_functions ($invocant) {
    my $self = _self($invocant);
    $self->{functions}->%*;
}

# Search all packages for a function matching a bare name.
# Returns ($sig) or undef.
sub search_function_by_name ($invocant, $name) {
    my $self = _self($invocant);
    my $suffix = "::${name}";
    for my $fqn (keys $self->{functions}->%*) {
        if (substr($fqn, -length($suffix)) eq $suffix) {
            return $self->{functions}{$fqn};
        }
    }
    undef;
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
        $self->{functions}{$fqn} //= $other->{functions}{$fqn};
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
