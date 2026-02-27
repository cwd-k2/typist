package Typist::Registry;
use v5.40;

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
        packages  => +{},
        resolving  => +{},
        newtypes   => +{},
        typeclasses => +{},
        instances   => +{},
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
    $self->{aliases}{$name} = $expr;
    delete $self->{resolved}{$name};
}

sub lookup_type ($invocant, $name) {
    my $self = _self($invocant);
    return $self->{resolved}{$name} if exists $self->{resolved}{$name};

    # Newtypes take precedence over aliases
    return $self->{newtypes}{$name} if exists $self->{newtypes}{$name};

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
    exists $self->{aliases}{$name} || exists $self->{newtypes}{$name};
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

# ── Variable Tracking ───────────────────────────

sub register_variable ($invocant, $info) {
    my $self = _self($invocant);
    my $key = $info->{ref} // die "register_variable requires ref";
    $self->{variables}{"$key"} = $info;
}

sub all_variables ($invocant) {
    my $self = _self($invocant);
    values $self->{variables}->%*;
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

sub resolve_instance ($invocant, $class_name, $type) {
    my $self = _self($invocant);
    my $insts = $self->{instances}{$class_name} // return undef;

    require Typist::Subtype;

    for my $inst (@$insts) {
        my $type_expr = $inst->type_expr;

        # HKT: match by constructor name (e.g., "ArrayRef" matches ArrayRef[T])
        if ($type->is_param && $type_expr eq $type->base) {
            return $inst;
        }

        my $inst_type = Typist::Parser->parse($type_expr);
        # Exact match or subtype match
        if ($type->equals($inst_type)
            || Typist::Subtype->is_subtype($type, $inst_type)) {
            return $inst;
        }
    }
    undef;
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
    if ($other->{effects}) {
        for my $name (keys $other->{effects}->%*) {
            $self->{effects}{$name} //= $other->{effects}{$name};
        }
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
        $invocant->{packages}  = +{};
        $invocant->{resolving} = +{};
        $invocant->{newtypes}   = +{};
        $invocant->{typeclasses} = +{};
        $invocant->{instances}   = +{};
        $invocant->{effects}     = +{};
    } else {
        $DEFAULT = undef;
    }
}

# ── Exported typedef ────────────────────────────

sub typedef ($name, $expr) {
    __PACKAGE__->define_alias($name, $expr);
}

1;
