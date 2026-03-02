package Typist::Prelude;
use v5.40;

our $VERSION = '0.01';

use Typist::Parser;
use Typist::Type::Eff;
use Typist::Effect;

# ── Builtin Function Type Annotations ────────────
#
# Standard type annotations for Perl builtins, installed into the
# registry under the CORE:: namespace.  User `declare` statements
# override these entries — register_function uses plain assignment.

my %BUILTINS = (
    # ── IO ────────────────────────────────────────
    say     => '(...Any) -> Bool !Eff(IO)',
    print   => '(...Any) -> Bool !Eff(IO)',
    warn    => '(...Any) -> Bool !Eff(IO)',
    die     => '(...Any) -> Never !Eff(Exn)',
    open    => '(...Any) -> Bool !Eff(IO)',
    close   => '(Any) -> Bool !Eff(IO)',
    read    => '(Any, Any, Int) -> Int !Eff(IO)',
    write   => '(Any, Any, Int) -> Int !Eff(IO)',
    binmode => '(Any) -> Bool !Eff(IO)',
    eof     => '(Any) -> Bool !Eff(IO)',
    seek    => '(Any, Int, Int) -> Bool !Eff(IO)',
    tell    => '(Any) -> Int !Eff(IO)',

    # ── String operations ─────────────────────────
    length  => '(Str) -> Int',
    substr  => '(Str, Int, ...Int) -> Str',
    uc      => '(Str) -> Str',
    lc      => '(Str) -> Str',
    ucfirst => '(Str) -> Str',
    lcfirst => '(Str) -> Str',
    index   => '(Str, Str, ...Int) -> Int',
    rindex  => '(Str, Str, ...Int) -> Int',
    chomp   => '(Any) -> Int',
    chop    => '(Any) -> Str',
    chr     => '(Int) -> Str',
    ord     => '(Str) -> Int',
    hex     => '(Str) -> Int',
    oct     => '(Str) -> Int',
    quotemeta => '(Str) -> Str',
    sprintf => '(Str, ...Any) -> Str',

    # ── Numeric operations ────────────────────────
    abs     => '(Num) -> Num',
    int     => '(Num) -> Int',
    sqrt    => '(Num) -> Num',
    log     => '(Num) -> Num',
    exp     => '(Num) -> Num',
    sin     => '(Num) -> Num',
    cos     => '(Num) -> Num',
    atan2   => '(Num, Num) -> Num',
    rand    => '(...Num) -> Num',
    srand   => '(...Int) -> Int',

    # ── Type/value introspection ──────────────────
    defined     => '(Any) -> Bool',
    ref         => '(Any) -> Str',
    wantarray   => '() -> Bool',
    caller      => '(...Int) -> Any',

    # ── Array operations ──────────────────────────
    scalar  => '(Any) -> Int',
    push    => '(Any, ...Any) -> Int',
    pop     => '(Any) -> Any',
    shift   => '(...Any) -> Any',
    unshift => '(Any, ...Any) -> Int',
    splice  => '(Any, ...Any) -> Any',
    reverse => '(...Any) -> Any',
    sort    => '(...Any) -> Any',
    map     => '(Any, ...Any) -> Any',
    grep    => '(Any, ...Any) -> Any',

    # ── Hash operations ───────────────────────────
    keys    => '(Any) -> Any',
    values  => '(Any) -> Any',
    each    => '(Any) -> Any',
    delete  => '(Any) -> Any',
    exists  => '(Any) -> Bool',

    # ── String matching ───────────────────────────
    split   => '(Any, ...Any) -> Any',
    join    => '(Str, ...Any) -> Str',
    pack    => '(Str, ...Any) -> Str',
    unpack  => '(Str, Str) -> Any',

    # ── Misc ──────────────────────────────────────
    eval    => '(Any) -> Any',
    require => '(Any) -> Bool',
    use     => '(Any) -> Bool',
    exit    => '(...Int) -> Never',
    system  => '(...Any) -> Int !Eff(IO)',
    exec    => '(...Any) -> Never !Eff(IO)',
    sleep   => '(...Int) -> Int',
    time    => '() -> Int',
    localtime => '(...Int) -> Any',
    gmtime  => '(...Int) -> Any',

    # ── Typist builtins ──────────────────────────
    typedef   => '(...Any) -> Void',
    newtype   => '(...Any) -> Void',
    effect    => '(...Any) -> Void',
    typeclass => '(...Any) -> Void',
    instance  => '(...Any) -> Void',
    declare   => '(Str, Str) -> Void',
    datatype  => '(...Any) -> Void',
    enum      => '(...Any) -> Void',
    unwrap    => '(Any) -> Any',
);

# ── Standard Effect Labels ───────────────────────
#
# Effects referenced by the builtin annotations above.  Registered so
# the Checker does not report them as UnknownEffect.

my @EFFECTS = qw(IO Exn);

# ── Public API ───────────────────────────────────

sub builtin_names ($class) { keys %BUILTINS }

sub install ($class, $registry) {
    # Register standard effect labels
    for my $eff_name (@EFFECTS) {
        next if $registry->lookup_effect($eff_name);
        $registry->register_effect(
            $eff_name,
            Typist::Effect->new(name => $eff_name, operations => +{}),
        );
    }

    for my $name (sort keys %BUILTINS) {
        my $ann = eval { Typist::Parser->parse_annotation($BUILTINS{$name}) };
        next if $@;

        my $type = $ann->{type};
        next unless $type->is_func;

        my @params  = $type->params;
        my $returns = $type->returns;
        my $effects = $type->effects
            ? Typist::Type::Eff->new($type->effects) : undef;

        $registry->register_function('CORE', $name, +{
            params       => \@params,
            returns      => $returns,
            effects      => $effects,
            variadic     => $type->variadic,
            params_expr  => [map { $_->to_string } @params],
            returns_expr => $returns->to_string,
        });
    }
}

1;
