package Typist::Registry;
use v5.40;

use Typist::Parser;

# ── Singleton State ───────────────────────────────

my %ALIASES;     # name -> type expression string
my %RESOLVED;    # name -> Type object (cached)
my %VARIABLES;   # refaddr -> { ref => $ref, type => $type, pkg => $pkg, name => $name }
my %FUNCTIONS;   # "pkg::name" -> { params => $type, returns => $type, generics => [...] }
my %PACKAGES;    # pkg -> 1
my %RESOLVING;   # cycle detection guard

# ── Alias Management ─────────────────────────────

sub define_alias ($class, $name, $expr) {
    $ALIASES{$name} = $expr;
    delete $RESOLVED{$name};
}

sub lookup_type ($class, $name) {
    return $RESOLVED{$name} if exists $RESOLVED{$name};

    my $expr = $ALIASES{$name} // return undef;

    if ($RESOLVING{$name}) {
        die "Typist: alias cycle detected involving '$name'";
    }

    local $RESOLVING{$name} = 1;
    my $type = Typist::Parser->parse($expr);

    # Eagerly resolve if the parsed result is itself an alias
    if ($type->is_alias) {
        my $inner = $class->lookup_type($type->alias_name);
        $type = $inner if $inner;
    }

    $RESOLVED{$name} = $type;
    $type;
}

sub has_alias ($class, $name) {
    exists $ALIASES{$name};
}

sub all_aliases ($class) {
    %ALIASES;
}

# ── Variable Tracking ────────────────────────────

sub register_variable ($class, $info) {
    my $key = $info->{ref} // die "register_variable requires ref";
    $VARIABLES{"$key"} = $info;
}

sub all_variables ($class) {
    values %VARIABLES;
}

# ── Function Tracking ────────────────────────────

sub register_function ($class, $pkg, $name, $sig) {
    $FUNCTIONS{"${pkg}::${name}"} = $sig;
}

sub lookup_function ($class, $pkg, $name) {
    $FUNCTIONS{"${pkg}::${name}"};
}

sub all_functions ($class) {
    %FUNCTIONS;
}

# ── Package Tracking ─────────────────────────────

sub register_package ($class, $pkg) {
    $PACKAGES{$pkg} = 1;
}

sub all_packages ($class) {
    keys %PACKAGES;
}

# ── Utility ──────────────────────────────────────

sub reset ($class) {
    %ALIASES   = ();
    %RESOLVED  = ();
    %VARIABLES = ();
    %FUNCTIONS = ();
    %PACKAGES  = ();
    %RESOLVING = ();
}

# ── Exported typedef ─────────────────────────────

sub typedef ($name, $expr) {
    __PACKAGE__->define_alias($name, $expr);
}

1;
