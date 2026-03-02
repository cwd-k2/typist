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
    rand    => '(...Num) -> Num !Eff(IO)',
    srand   => '(...Int) -> Int !Eff(IO)',

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
    eval    => '(Any) -> Any !Eff(Exn)',
    require => '(Any) -> Bool !Eff(IO)',
    use     => '(Any) -> Bool !Eff(IO)',
    exit    => '(...Int) -> Never !Eff(Exn)',
    system  => '(...Any) -> Int !Eff(IO)',
    exec    => '(...Any) -> Never !Eff(IO)',
    sleep   => '(...Int) -> Int !Eff(IO)',
    time    => '() -> Int !Eff(IO)',
    localtime => '(...Int) -> Any !Eff(IO)',
    gmtime  => '(...Int) -> Any !Eff(IO)',

    # ── Typist builtins ──────────────────────────
    typedef   => '(...Any) -> Void !Eff(Decl)',
    newtype   => '(...Any) -> Void !Eff(Decl)',
    effect    => '(...Any) -> Void !Eff(Decl)',
    typeclass => '(...Any) -> Void !Eff(Decl)',
    instance  => '(...Any) -> Void !Eff(Decl)',
    declare   => '(Str, Str) -> Void !Eff(Decl)',
    datatype  => '(...Any) -> Void !Eff(Decl)',
    enum      => '(...Any) -> Void !Eff(Decl)',
    struct    => '(...Any) -> Void !Eff(Decl)',
    unwrap    => '(Any) -> Any',
);

# ── Standard Effect Labels ───────────────────────
#
# Effects referenced by the builtin annotations above.  Registered so
# the Checker does not report them as UnknownEffect.

my @EFFECTS = qw(IO Exn Decl);

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

=encoding utf8

=head1 NAME

Typist::Prelude - Builtin function type annotations for Perl core

=head1 SYNOPSIS

    use Typist::Prelude;

    # Install builtins into a registry
    Typist::Prelude->install($registry);

    # Query registered builtin names
    my @names = Typist::Prelude->builtin_names;

=head1 DESCRIPTION

Provides standard type annotations for 84 Perl builtin functions
(74 core + 10 Typist builtins) and registers them under the C<CORE::>
namespace. Also registers standard effect labels (C<IO>, C<Exn>, C<Decl>).

User C<declare> statements override prelude entries — registration
uses plain assignment, so later writes win.

=head1 METHODS

=head2 install

    Typist::Prelude->install($registry);

Registers all builtin function signatures and standard effect labels
into the given L<Typist::Registry> instance.

=head2 builtin_names

    my @names = Typist::Prelude->builtin_names;

Returns the list of all registered builtin function names. This is the
single source of truth used by L<Typist::LSP::Document> and
L<Typist::Static::EffectChecker>.

=head1 SEE ALSO

L<Typist>, L<Typist::Registry>, L<Typist::Parser>

=cut
