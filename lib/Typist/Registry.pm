package Typist::Registry;
use v5.40;

use Typist::Parser;

# ── Default Instance ─────────────────────────────

my $DEFAULT;
sub _default ($class) { $DEFAULT //= $class->new }

# ── Constructor ──────────────────────────────────

sub new ($class, %args) {
    bless {
        aliases   => {},
        resolved  => {},
        variables => {},
        functions => {},
        packages  => {},
        resolving => {},
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

    my $expr = $self->{aliases}{$name} // return undef;

    if ($self->{resolving}{$name}) {
        die "Typist: alias cycle detected involving '$name'";
    }

    $self->{resolving}{$name} = 1;
    my $type = eval {
        my $parsed = Typist::Parser->parse($expr);

        # Eagerly resolve if the parsed result is itself an alias
        if ($parsed->is_alias) {
            my $inner = $self->lookup_type($parsed->alias_name);
            $parsed = $inner if $inner;
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
    exists $self->{aliases}{$name};
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

# ── Merge ────────────────────────────────────────

sub merge ($self, $other) {
    for my $name (keys $other->{aliases}->%*) {
        $self->{aliases}{$name} //= $other->{aliases}{$name};
    }
    for my $fqn (keys $other->{functions}->%*) {
        $self->{functions}{$fqn} //= $other->{functions}{$fqn};
    }
    # Clear resolved cache since new aliases may change resolution
    $self->{resolved} = {};
    $self;
}

# ── Utility ─────────────────────────────────────

sub reset ($invocant) {
    if (ref $invocant) {
        $invocant->{aliases}   = {};
        $invocant->{resolved}  = {};
        $invocant->{variables} = {};
        $invocant->{functions} = {};
        $invocant->{packages}  = {};
        $invocant->{resolving} = {};
    } else {
        $DEFAULT = undef;
    }
}

# ── Exported typedef ────────────────────────────

sub typedef ($name, $expr) {
    __PACKAGE__->define_alias($name, $expr);
}

1;
