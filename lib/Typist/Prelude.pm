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
    say     => '(...Any) -> Bool ![IO]',
    print   => '(...Any) -> Bool ![IO]',
    warn    => '(...Any) -> Bool ![IO]',
    die     => '(...Any) -> Never ![Exn]',
    open    => '(...Any) -> Bool ![IO]',
    close   => '(Any) -> Bool ![IO]',
    read    => '(Any, Any, Int) -> Int ![IO]',
    write   => '(Any, Any, Int) -> Int ![IO]',
    binmode => '(Any) -> Bool ![IO]',
    eof     => '(Any) -> Bool ![IO]',
    seek    => '(Any, Int, Int) -> Bool ![IO]',
    tell    => '(Any) -> Int ![IO]',

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
    abs     => '<T: Num>(T) -> T',
    int     => '(Num) -> Int',
    sqrt    => '(Num) -> Double',
    log     => '(Num) -> Double',
    exp     => '(Num) -> Double',
    sin     => '(Num) -> Double',
    cos     => '(Num) -> Double',
    atan2   => '(Num, Num) -> Double',
    rand    => '(...Num) -> Double ![IO]',
    srand   => '(...Int) -> Int ![IO]',

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
    eval    => '(Any) -> Any ![Exn]',
    require => '(Any) -> Bool ![IO]',
    use     => '(Any) -> Bool ![IO]',
    exit    => '(...Int) -> Never ![Exn]',
    system  => '(...Any) -> Int ![IO]',
    exec    => '(...Any) -> Never ![IO]',
    sleep   => '(...Int) -> Int ![IO]',
    time    => '() -> Int ![IO]',
    localtime => '(...Int) -> Any ![IO]',
    gmtime  => '(...Int) -> Any ![IO]',

    # ── Typist builtins ──────────────────────────
    typedef   => '(...Any) -> Void ![Decl]',
    newtype   => '(...Any) -> Void ![Decl]',
    effect    => '(...Any) -> Void ![Decl]',
    typeclass => '(...Any) -> Void ![Decl]',
    instance  => '(...Any) -> Void ![Decl]',
    declare   => '(Str, Str) -> Void ![Decl]',
    datatype  => '(...Any) -> Void ![Decl]',
    enum      => '(...Any) -> Void ![Decl]',
    struct    => '(...Any) -> Void ![Decl]',
);

# ── Standard Effect Labels ───────────────────────
#
# Effects referenced by the builtin annotations above.  Registered so
# the Checker does not report them as UnknownEffect.

my @EFFECTS = qw(IO Decl);

# Exn is special: ambient + has a throw operation + Exn::throw bridges to die
my $EXN_EFFECT = Typist::Effect->new(
    name       => 'Exn',
    operations => +{ throw => '(Any) -> Never' },
    ambient    => 1,
);

my %TYPIST_BUILTIN_SET = map { $_ => 1 }
    qw(typedef newtype effect typeclass instance declare datatype enum struct);

# ── Public API ───────────────────────────────────

sub builtin_names ($class) { keys %BUILTINS }

sub is_typist_builtin ($class, $name) { $TYPIST_BUILTIN_SET{$name} }

sub install ($class, $registry) {
    # Register standard effect labels (ambient — no handler required)
    for my $eff_name (@EFFECTS) {
        next if $registry->lookup_effect($eff_name);
        $registry->register_effect(
            $eff_name,
            Typist::Effect->new(name => $eff_name, operations => +{}, ambient => 1),
        );
    }

    # Exn: ambient effect with throw operation, bridged to Perl's die
    unless ($registry->lookup_effect('Exn')) {
        $registry->register_effect('Exn', $EXN_EFFECT);
        no strict 'refs';
        *{"Exn::throw"} = sub ($err) { die $err } unless defined &Exn::throw;
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

        # Parse generics from annotation (e.g., <T: Num> → [{name => 'T', bound_expr => 'Num'}])
        my @generics;
        for my $g (@{$ann->{generics_raw} // []}) {
            my ($gname, $bound) = split /:/, $g, 2;
            $gname =~ s/\s//g;
            if (defined $bound) { $bound =~ s/\A\s+//; $bound =~ s/\s+\z//; }
            push @generics, { name => $gname, bound_expr => $bound };
        }

        $registry->register_function('CORE', $name, +{
            params       => \@params,
            returns      => $returns,
            effects      => $effects,
            variadic     => $type->variadic,
            generics     => \@generics,
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
