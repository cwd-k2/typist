package Typist::Prelude;
use v5.40;

use Typist::Parser;
use Typist::Type::Eff;
use Typist::Effect;

# ── Builtin Function Type Annotations ────────────
#
# Standard type annotations for Perl builtins, installed into the
# registry under the CORE:: namespace.  User `declare` statements
# override these entries — register_function uses plain assignment.

my %BUILTINS = (
    # IO effects
    say     => '(Any) -> Bool !Eff(IO)',
    print   => '(Any) -> Bool !Eff(IO)',
    warn    => '(Any) -> Bool !Eff(IO)',
    die     => '(Any) -> Never !Eff(Exn)',

    # Pure string operations
    length  => '(Str) -> Int',
    substr  => '(Str, Int, Int) -> Str',
    uc      => '(Str) -> Str',
    lc      => '(Str) -> Str',
    index   => '(Str, Str) -> Int',

    # Pure numeric operations
    abs     => '(Num) -> Num',
    int     => '(Num) -> Int',
    sqrt    => '(Num) -> Num',

    # Pure list operations
    scalar  => '(Any) -> Int',
    reverse => '(Any) -> Any',
    sort    => '(Any) -> Any',

    # IO operations
    open    => '(Any, Any) -> Bool !Eff(IO)',
    close   => '(Any) -> Bool !Eff(IO)',
    chomp   => '(Any) -> Int',
    chop    => '(Any) -> Str',
);

# ── Standard Effect Labels ───────────────────────
#
# Effects referenced by the builtin annotations above.  Registered so
# the Checker does not report them as UnknownEffect.

my @EFFECTS = qw(IO Exn);

# ── Public API ───────────────────────────────────

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
            params      => \@params,
            returns     => $returns,
            effects     => $effects,
            params_expr => [map { $_->to_string } @params],
            returns_expr => $returns->to_string,
        });
    }
}

1;
