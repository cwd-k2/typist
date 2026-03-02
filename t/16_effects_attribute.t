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

# ── Functions with :Type (compiled after effects are registered) ──

sub greet :Type((Str) -> Str ![Console]) ($name) {
    "Hello, $name!";
}

sub main_fn :Type(() -> Void ![Console, State]) () {
    undef;
}

sub logged :Type(<a, r: Row>(Str) -> Str ![Log, r]) ($msg) {
    $msg;
}

sub pure_effect :Type(() -> Any ![Console]) () {
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

subtest 'function with :Type registers effects in sig' => sub {
    my $sig = Typist::Registry->lookup_function('main', 'greet');
    ok $sig, 'sig registered';
    ok $sig->{effects}, 'effects present';
    ok $sig->{effects}->is_eff, 'is_eff';
    is $sig->{effects}->to_string, '[Console]', '[Console]';
};

subtest 'function with multiple effects' => sub {
    my $sig = Typist::Registry->lookup_function('main', 'main_fn');
    ok $sig->{effects}, 'effects present';
    is $sig->{effects}->to_string, '[Console, State]', 'multi-effect';
};

subtest 'function with :Type and generics(r: Row)' => sub {
    my $sig = Typist::Registry->lookup_function('main', 'logged');
    ok $sig->{effects}, 'effects present';
    is $sig->{effects}->to_string, '[Log, r]', 'open row with row_var';

    my @gs = $sig->{generics}->@*;
    is scalar(@gs), 2, 'two generics';
    is $gs[0]{name}, 'a', 'first generic: a';
    is $gs[1]{name}, 'r', 'second generic: r';
    ok $gs[1]{is_row_var}, 'r is row_var';
};

subtest 'Eff does not affect runtime behavior (phantom)' => sub {
    my $result = greet("world");
    is $result, "Hello, world!", 'function works normally despite effects';
};

subtest 'function with only effect annotation' => sub {
    my $sig = Typist::Registry->lookup_function('main', 'pure_effect');
    ok $sig, 'sig registered for eff-only function';
    ok $sig->{effects}, 'effects present';
    is $sig->{effects}->to_string, '[Console]', 'correct effect';

    my $r = pure_effect();
    is $r, 42, 'eff-only function works';
};

done_testing;
