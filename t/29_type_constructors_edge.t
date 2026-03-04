use v5.40;
use Test::More;
use lib 'lib';
use Typist::Type::Atom;
use Typist::Type::Var;
use Typist::Type::Union;
use Typist::Type::Intersection;
use Typist::Type::Func;
use Typist::Type::Record;
use Typist::Type::Row;
use Typist::Type::Literal;
use Typist::Type::Quantified;
use Typist::Type::Param;

# ── Union edge cases ────────────────────────────

subtest 'Union: deep flatten' => sub {
    my $int = Typist::Type::Atom->new('Int');
    my $str = Typist::Type::Atom->new('Str');
    my $bool = Typist::Type::Atom->new('Bool');
    my $num = Typist::Type::Atom->new('Num');

    # Union(Union(Int, Str), Union(Bool, Num)) → flat Union(Int, Str, Bool, Num)
    my $inner1 = Typist::Type::Union->new($int, $str);
    my $inner2 = Typist::Type::Union->new($bool, $num);
    my $outer = Typist::Type::Union->new($inner1, $inner2);
    ok $outer->is_union, 'nested unions flatten to union';
    is scalar($outer->members), 4, 'four members after deep flatten';
};

subtest 'Union: single member collapse' => sub {
    my $int = Typist::Type::Atom->new('Int');
    my $result = Typist::Type::Union->new($int);
    ok $result->is_atom, 'single-member union collapses to atom';
    is $result->to_string, 'Int', 'collapsed to Int';
};

subtest 'Union: dedup' => sub {
    my $int1 = Typist::Type::Atom->new('Int');
    my $int2 = Typist::Type::Atom->new('Int');
    my $str = Typist::Type::Atom->new('Str');
    my $u = Typist::Type::Union->new($int1, $int2, $str);
    is scalar($u->members), 2, 'duplicate Int deduplicated';
};

subtest 'Union: reorder equality' => sub {
    my $int = Typist::Type::Atom->new('Int');
    my $str = Typist::Type::Atom->new('Str');
    my $u1 = Typist::Type::Union->new($int, $str);
    my $u2 = Typist::Type::Union->new($str, $int);
    ok $u1->equals($u2), 'Union(Int, Str) equals Union(Str, Int)';
};

subtest 'Union: free_vars' => sub {
    my $var_t = Typist::Type::Var->new('T');
    my $int = Typist::Type::Atom->new('Int');
    my $u = Typist::Type::Union->new($var_t, $int);
    my @fv = $u->free_vars;
    is_deeply \@fv, ['T'], 'free_vars collects from members';
};

subtest 'Union: substitute' => sub {
    my $var_t = Typist::Type::Var->new('T');
    my $int = Typist::Type::Atom->new('Int');
    my $str = Typist::Type::Atom->new('Str');
    my $u = Typist::Type::Union->new($var_t, $int);
    my $result = $u->substitute({ T => $str });
    ok $result->is_union, 'substituted union is still union';
    my @m = $result->members;
    ok((grep { $_->to_string eq 'Str' } @m), 'T substituted to Str');
    ok((grep { $_->to_string eq 'Int' } @m), 'Int preserved');
};

# ── Intersection edge cases ─────────────────────

subtest 'Intersection: deep flatten' => sub {
    my $a = Typist::Type::Atom->new('A');
    my $b = Typist::Type::Atom->new('B');
    my $c = Typist::Type::Atom->new('C');
    my $inner = Typist::Type::Intersection->new($a, $b);
    my $outer = Typist::Type::Intersection->new($inner, $c);
    ok $outer->is_intersection, 'nested intersections flatten';
    is scalar($outer->members), 3, 'three members';
};

subtest 'Intersection: single member collapse' => sub {
    my $int = Typist::Type::Atom->new('Int');
    my $result = Typist::Type::Intersection->new($int);
    ok $result->is_atom, 'single-member intersection collapses';
    is $result->to_string, 'Int', 'collapsed to Int';
};

subtest 'Intersection: free_vars and substitute' => sub {
    my $var_t = Typist::Type::Var->new('T');
    my $var_u = Typist::Type::Var->new('U');
    my $i = Typist::Type::Intersection->new($var_t, $var_u);
    my @fv = sort $i->free_vars;
    is_deeply \@fv, [qw(T U)], 'free_vars from both members';

    my $int = Typist::Type::Atom->new('Int');
    my $result = $i->substitute({ T => $int });
    ok $result->is_intersection, 'substituted intersection';
    my @m = $result->members;
    ok((grep { $_->to_string eq 'Int' } @m), 'T substituted');
    ok((grep { $_->to_string eq 'U' } @m), 'U preserved');
};

# ── Func edge cases ─────────────────────────────

subtest 'Func: empty params + effects' => sub {
    my $row = Typist::Type::Row->new(labels => ['IO']);
    my $f = Typist::Type::Func->new([], Typist::Type::Atom->new('Void'), $row);
    ok $f->is_func, 'zero-param func with effects';
    is scalar($f->params), 0, 'no params';
    ok $f->effects, 'has effects';
    like $f->to_string, qr/\(\) -> Void !\[IO\]/, 'to_string includes effects';
};

subtest 'Func: free_vars traversal' => sub {
    my $var_t = Typist::Type::Var->new('T');
    my $var_u = Typist::Type::Var->new('U');
    my $f = Typist::Type::Func->new([$var_t], $var_u);
    my @fv = sort $f->free_vars;
    is_deeply \@fv, [qw(T U)], 'free_vars from params and return';
};

subtest 'Func: free_vars includes effect row var' => sub {
    my $row = Typist::Type::Row->new(labels => ['IO'], row_var => 'r');
    my $f = Typist::Type::Func->new(
        [Typist::Type::Atom->new('Int')],
        Typist::Type::Atom->new('Int'),
        $row,
    );
    my @fv = $f->free_vars;
    ok((grep { $_ eq 'r' } @fv), 'row var r in free_vars');
};

subtest 'Func: substitute propagation' => sub {
    my $var_t = Typist::Type::Var->new('T');
    my $int = Typist::Type::Atom->new('Int');
    my $f = Typist::Type::Func->new([$var_t], $var_t);
    my $result = $f->substitute({ T => $int });
    is(($result->params)[0]->to_string, 'Int', 'param substituted');
    is $result->returns->to_string, 'Int', 'return substituted';
};

subtest 'Func: variadic to_string' => sub {
    my $int = Typist::Type::Atom->new('Int');
    my $str = Typist::Type::Atom->new('Str');
    my $f = Typist::Type::Func->new([$int, $str], Typist::Type::Atom->new('Void'), undef, variadic => 1);
    like $f->to_string, qr/\.\.\.Str/, 'variadic param has ... prefix';
};

# ── Record edge cases ───────────────────────────

subtest 'Record: empty record' => sub {
    my $r = Typist::Type::Record->new();
    ok $r->is_record, 'empty record is record';
    is scalar(keys %{{ $r->required_fields }}), 0, 'no required fields';
    is scalar(keys %{{ $r->optional_fields }}), 0, 'no optional fields';
    is $r->to_string, '{}', 'empty record to_string';
};

subtest 'Record: optional field covariance' => sub {
    my $int = Typist::Type::Atom->new('Int');
    my $r = Typist::Type::Record->new('name' => Typist::Type::Atom->new('Str'), 'age?' => $int);
    my %opt = $r->optional_fields;
    ok exists $opt{age}, 'age is optional';
    is $opt{age}->to_string, 'Int', 'optional field type preserved';
};

subtest 'Record: free_vars from fields' => sub {
    my $var_t = Typist::Type::Var->new('T');
    my $r = Typist::Type::Record->new(x => $var_t, y => Typist::Type::Atom->new('Int'));
    my @fv = $r->free_vars;
    ok((grep { $_ eq 'T' } @fv), 'T in free_vars');
};

subtest 'Record: substitute' => sub {
    my $var_t = Typist::Type::Var->new('T');
    my $int = Typist::Type::Atom->new('Int');
    my $r = Typist::Type::Record->new(x => $var_t);
    my $result = $r->substitute({ T => $int });
    my %req = $result->required_fields;
    is $req{x}->to_string, 'Int', 'field type substituted';
};

# ── Row edge cases ──────────────────────────────

subtest 'Row: empty row' => sub {
    my $r = Typist::Type::Row->new(labels => []);
    ok $r->is_row, 'empty row is row';
    ok $r->is_empty, 'empty row is_empty';
    ok $r->is_closed, 'empty row is closed';
    is $r->to_string, '', 'empty row to_string';
};

subtest 'Row: duplicate label dedup' => sub {
    my $r = Typist::Type::Row->new(labels => [qw(IO IO Console)]);
    is_deeply [$r->labels], [qw(Console IO)], 'duplicates removed and sorted';
};

subtest 'Row: labels sorted' => sub {
    my $r = Typist::Type::Row->new(labels => [qw(Z A M)]);
    is_deeply [$r->labels], [qw(A M Z)], 'labels sorted';
};

subtest 'Row: substitute merge' => sub {
    my $r1 = Typist::Type::Row->new(labels => ['A'], row_var => 'r');
    my $r2 = Typist::Type::Row->new(labels => ['B', 'C']);
    my $result = $r1->substitute({ r => $r2 });
    ok $result->is_row, 'merged result is row';
    is_deeply [$result->labels], [qw(A B C)], 'labels merged and sorted';
    ok $result->is_closed, 'merged row is closed (r2 has no var)';
};

subtest 'Row: substitute merge with label states' => sub {
    my $r1 = Typist::Type::Row->new(
        labels => ['DB'],
        row_var => 'r',
        label_states => +{ DB => { from => 'None', to => 'Connected' } },
    );
    my $r2 = Typist::Type::Row->new(labels => ['IO']);
    my $result = $r1->substitute({ r => $r2 });
    is_deeply [$result->labels], [qw(DB IO)], 'labels merged';
    my $st = $result->label_state('DB');
    is_deeply $st->{from}, ['None'], 'DB state preserved from';
    is_deeply $st->{to}, ['Connected'], 'DB state preserved to';
};

subtest 'Row: free_vars' => sub {
    my $open = Typist::Type::Row->new(labels => ['IO'], row_var => 'r');
    my @fv = $open->free_vars;
    is_deeply \@fv, ['r'], 'open row has free var r';

    my $closed = Typist::Type::Row->new(labels => ['IO']);
    my @fv2 = $closed->free_vars;
    is_deeply \@fv2, [], 'closed row has no free vars';
};

subtest 'Row: equals with label_states' => sub {
    my $r1 = Typist::Type::Row->new(
        labels => ['IO'],
        label_states => +{ IO => { from => 'Init', to => 'Done' } },
    );
    my $r2 = Typist::Type::Row->new(
        labels => ['IO'],
        label_states => +{ IO => { from => 'Init', to => 'Done' } },
    );
    my $r3 = Typist::Type::Row->new(
        labels => ['IO'],
    );
    my $r4 = Typist::Type::Row->new(
        labels => ['IO'],
        label_states => +{ IO => { from => 'Init', to => 'Open' } },
    );
    ok  $r1->equals($r2), 'same label_states are equal';
    ok !$r1->equals($r3), 'with states != without states';
    ok !$r1->equals($r4), 'different to state not equal';
};

# ── Literal edge cases ──────────────────────────

subtest 'Literal: equality with different base' => sub {
    my $lit_int = Typist::Type::Literal->new(42, 'Int');
    my $lit_dbl = Typist::Type::Literal->new(42, 'Double');
    ok !$lit_int->equals($lit_dbl), 'Literal(42,Int) != Literal(42,Double)';
};

subtest 'Literal: contains' => sub {
    my $lit = Typist::Type::Literal->new(42, 'Int');
    ok $lit->contains(42), 'contains matching value';
    ok !$lit->contains(7), 'does not contain non-matching value';
};

subtest 'Literal: free_vars empty' => sub {
    my $lit = Typist::Type::Literal->new("hello", 'Str');
    is_deeply [$lit->free_vars], [], 'literal has no free vars';
};

subtest 'Literal: substitute is identity' => sub {
    my $lit = Typist::Type::Literal->new(42, 'Int');
    my $result = $lit->substitute({ T => Typist::Type::Atom->new('Str') });
    ok $lit->equals($result), 'substitute on literal is identity';
};

# ── Quantified edge cases ───────────────────────

subtest 'Quantified: free_vars excludes bound vars' => sub {
    my $q = Typist::Type::Quantified->new(
        vars => [{ name => 'T' }],
        body => Typist::Type::Func->new(
            [Typist::Type::Var->new('T'), Typist::Type::Var->new('U')],
            Typist::Type::Var->new('T'),
        ),
    );
    my @fv = $q->free_vars;
    is_deeply \@fv, ['U'], 'T excluded (bound), U included (free)';
};

subtest 'Quantified: capture-safe substitution' => sub {
    my $q = Typist::Type::Quantified->new(
        vars => [{ name => 'T' }],
        body => Typist::Type::Func->new(
            [Typist::Type::Var->new('T')],
            Typist::Type::Var->new('U'),
        ),
    );
    # Substituting T should be blocked (bound), U should work
    my $result = $q->substitute({
        T => Typist::Type::Atom->new('Int'),
        U => Typist::Type::Atom->new('Str'),
    });
    ok $result->is_quantified, 'still quantified after substitute';
    # Body: T should remain as T (capture avoided), U should become Str
    my $body = $result->body;
    is(($body->params)[0]->to_string, 'T', 'bound var T not captured');
    is $body->returns->to_string, 'Str', 'free var U substituted';
};

subtest 'Quantified: nested quantification' => sub {
    # forall T. forall U. T -> U
    my $inner = Typist::Type::Quantified->new(
        vars => [{ name => 'U' }],
        body => Typist::Type::Func->new(
            [Typist::Type::Var->new('T')],
            Typist::Type::Var->new('U'),
        ),
    );
    my $outer = Typist::Type::Quantified->new(
        vars => [{ name => 'T' }],
        body => $inner,
    );
    ok $outer->is_quantified, 'outer is quantified';
    ok $outer->body->is_quantified, 'body is also quantified';
    my @fv = $outer->free_vars;
    is_deeply \@fv, [], 'no free vars in nested quantification';
};

subtest 'Quantified: to_string with compound bound' => sub {
    my $q = Typist::Type::Quantified->new(
        vars => [{ name => 'T', bound => Typist::Type::Intersection->new(
            Typist::Type::Atom->new('Num'), Typist::Type::Atom->new('Show'),
        )}],
        body => Typist::Type::Func->new(
            [Typist::Type::Var->new('T')],
            Typist::Type::Atom->new('Str'),
        ),
    );
    like $q->to_string, qr/T: Num \+ Show|T: Show \+ Num/,
        'compound bound uses + separator';
};

done_testing;
