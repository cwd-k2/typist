use v5.40;
use Test::More;

use Typist;

# Effect declarations must happen at compile time (before CHECK validates them).
BEGIN {
    effect Console => +{
        readLine  => 'CodeRef[-> Str]',
        writeLine => 'CodeRef[Str -> Void]',
    };

    effect State => +{
        get => 'CodeRef[-> Any]',
        put => 'CodeRef[Any -> Void]',
    };

    effect Log => +{
        log => 'CodeRef[Str -> Void]',
    };
}

# ── Functions with :Eff (compiled after effects are registered) ──

sub greet :Params(Str) :Returns(Str) :Eff(Console) ($name) {
    "Hello, $name!";
}

sub main_fn :Returns(Void) :Eff(Console | State) () {
    undef;
}

sub logged :Generic(a, r: Row) :Params(Str) :Returns(Str) :Eff(Log | r) ($msg) {
    $msg;
}

sub pure_effect :Eff(Console) () {
    42;
}

# ── Tests ────────────────────────────────────────

subtest 'effect keyword registers effect' => sub {
    ok Typist::Registry->is_effect_label('Console'), 'Console registered';
    my $eff = Typist::Registry->lookup_effect('Console');
    is $eff->name, 'Console', 'name';
    is_deeply [sort $eff->op_names], [qw(readLine writeLine)], 'operations';
};

subtest 'multiple effects registered' => sub {
    ok Typist::Registry->is_effect_label('State'), 'State registered';
    ok Typist::Registry->is_effect_label('Log'),   'Log registered';
};

subtest 'function with :Eff registers effects in sig' => sub {
    my $sig = Typist::Registry->lookup_function('main', 'greet');
    ok $sig, 'sig registered';
    ok $sig->{effects}, 'effects present';
    ok $sig->{effects}->is_eff, 'is_eff';
    is $sig->{effects}->to_string, 'Eff(Console)', 'Eff(Console)';
};

subtest 'function with multiple effects' => sub {
    my $sig = Typist::Registry->lookup_function('main', 'main_fn');
    ok $sig->{effects}, 'effects present';
    is $sig->{effects}->to_string, 'Eff(Console | State)', 'multi-effect';
};

subtest 'function with :Eff and :Generic(r: Row)' => sub {
    my $sig = Typist::Registry->lookup_function('main', 'logged');
    ok $sig->{effects}, 'effects present';
    is $sig->{effects}->to_string, 'Eff(Log | r)', 'open row with row_var';

    my @gs = $sig->{generics}->@*;
    is scalar(@gs), 2, 'two generics';
    is $gs[0]{name}, 'a', 'first generic: a';
    is $gs[1]{name}, 'r', 'second generic: r';
    ok $gs[1]{is_row_var}, 'r is row_var';
};

subtest 'Eff does not affect runtime behavior (phantom)' => sub {
    my $result = greet("world");
    is $result, "Hello, world!", 'function works normally despite :Eff';
};

subtest 'function with only :Eff (no :Params/:Returns)' => sub {
    my $sig = Typist::Registry->lookup_function('main', 'pure_effect');
    ok $sig, 'sig registered for eff-only function';
    ok $sig->{effects}, 'effects present';
    is $sig->{effects}->to_string, 'Eff(Console)', 'correct effect';

    my $r = pure_effect();
    is $r, 42, 'eff-only function works';
};

done_testing;
