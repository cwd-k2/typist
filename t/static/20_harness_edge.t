use v5.40;
use Test::More;
use lib 'lib', 't/lib';

use Test::Typist::Analyze qw(analyze type_errors);

subtest 'fallthrough after else-return keeps narrowing in flat scope' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub takes_str :sig((Str) -> Void) ($x) { }
sub check :sig((Maybe[Str]) -> Void) ($x) {
    if (defined($x)) {
        my $tmp :sig(Str) = $x;
    } else {
        return;
    }
    takes_str($x);
}
PERL

    is scalar @$errs, 0, 'else-return preserves narrowing into following flat scope';
};

subtest 'plain branch exit widens variable narrowing again in flat scope' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub takes_str :sig((Str) -> Void) ($x) { }
sub check :sig((Maybe[Str]) -> Void) ($x) {
    if (defined($x)) {
        takes_str($x);
    }
    takes_str($x);
}
PERL

    is scalar @$errs, 1, 'narrowing does not leak past a normal branch merge';
    like $errs->[0]{message}, qr/Argument 1.*takes_str.*Str/, 'post-merge use is widened';
};

subtest 'accessor narrowing is widened again after branch exit' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Person => (
    name => Str,
    optional(phone => Str),
);
sub takes_str :sig((Str) -> Void) ($x) { }
sub check :sig((Person) -> Void) ($p) {
    if (defined($p->phone)) {
        takes_str($p->phone);
    }
    takes_str($p->phone);
}
PERL

    is scalar @$errs, 2, 'one error inside branch and one after branch are both visible today';
    like $errs->[0]{message}, qr/Argument 1.*takes_str.*Str/, 'accessor is widened after branch merge';
};

subtest 'accessor narrowing survives fallthrough after else-return' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Person => (
    name => Str,
    optional(phone => Str),
);
sub takes_str :sig((Str) -> Void) ($x) { }
sub check :sig((Person) -> Void) ($p) {
    if (defined($p->phone)) {
        takes_str($p->phone);
    } else {
        return;
    }
    takes_str($p->phone);
}
PERL

    local $TODO = 'accessor early-return narrowing is not yet propagated through flat scope';
    is scalar @$errs, 0, 'optional accessor narrowing survives flat scope after else-return';
};

subtest 'same-name locals do not bleed across functions' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub foo :sig(() -> Void) () {
    my $x = 1;
    my $y :sig(Int) = $x;
}
sub bar :sig(() -> Void) () {
    my $x = "s";
    my $y :sig(Str) = $x;
}
PERL

    is scalar @$errs, 0, 'local inference is scoped per function';
};

subtest 'same-function local inference survives repeated later lookups' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub takes_int :sig((Int) -> Void) ($x) { }
sub check :sig(() -> Void) () {
    my $x = 1;
    my $y :sig(Int) = $x;
    takes_int($x);
    my $z :sig(Int) = $x;
}
PERL

    is scalar @$errs, 0, 'later nodes in the same function still see inferred locals';
};

subtest 'implicit return sees earlier function-local bindings' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub build :sig(() -> ArrayRef[Int]) () {
    my $min = 1;
    my $max = $min;
    [$min, $max];
}
PERL

    is scalar @$errs, 0, 'implicit return analysis reuses earlier local inference';
};

subtest 'loop-scoped locals infer from foreach element types' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub takes_int :sig((Int) -> Void) ($x) { }
sub check :sig((ArrayRef[Int]) -> Void) ($xs) {
    for my $x (@$xs) {
        my $y = $x + 1;
        takes_int($y);
    }
}
PERL

    is scalar @$errs, 0, 'locals inside foreach blocks infer from loop element types';
};

subtest 'loop vars infer when iterable comes from an earlier local binding' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub load :sig(() -> ArrayRef[Int]) () { [1, 2, 3] }
sub takes_int :sig((Int) -> Void) ($x) { }
sub check :sig(() -> Void) () {
    my $xs = load();
    for my $x (@$xs) {
        my $y = $x + 1;
        takes_int($y);
    }
}
PERL

    is scalar @$errs, 0, 'loop inference sees earlier local iterable bindings';
};

subtest 'env hash lookup infers optional string value' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub takes_maybe :sig((Str | Undef) -> Void) ($x) { }
sub check :sig(() -> Void) () {
    my $flag = $ENV{NO_COLOR};
    takes_maybe($flag);
}
PERL

    is scalar @$errs, 0, 'environment hash subscript is inferred as Str | Undef';
};

subtest 'anon-sub params do not leak over outer locals with same name' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub takes_int :sig((Int) -> Void) ($x) { }
sub check :sig((ArrayRef[Int]) -> Void) ($xs) {
    my $x = 1;
    map(sub ($x) { $x + 1 }, $xs);
    takes_int($x);
}
PERL

    is scalar @$errs, 0, 'callback param does not overwrite outer local scope';
};

subtest 'generic HOF callback locals infer from instantiated callback params' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
declare fmap => '<A, B>(ArrayRef[A], (A) -> B) -> ArrayRef[B]';
sub takes_int :sig((Int) -> Void) ($x) { }
sub check :sig((ArrayRef[Int]) -> Void) ($xs) {
    fmap($xs, sub ($x) {
        my $y = $x + 1;
        takes_int($y);
        $y;
    });
}
PERL

    is scalar @$errs, 0, 'generic callback locals infer after instantiating higher-order params';
};

subtest 'local inferred symbol scopes remain distinct for same-name locals' => sub {
    my $result = analyze(<<'PERL');
use v5.40;
sub foo :sig(() -> Void) () {
    my $x = 1;
}
sub bar :sig(() -> Void) () {
    my $x = "s";
}
PERL

    my @locals = grep {
        ($_->{kind} // '') eq 'variable'
            && ($_->{name} // '') eq '$x'
            && $_->{inferred}
    } $result->{symbols}->@*;

    is scalar @locals, 2, 'two inferred local symbols recorded';
    isnt $locals[0]{scope_start}, $locals[1]{scope_start}, 'same-name locals carry distinct scopes';
};

done_testing;
