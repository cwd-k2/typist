use v5.40;
use Test::More;
use lib 'lib';
use Typist::Parser;
use Typist::Subtype;
use Typist::Registry;
use Typist::Type::Newtype;

sub is_sub { Typist::Subtype->is_subtype(@_) }

# ── Type node basics ─────────────────────────────

subtest 'newtype node' => sub {
    my $inner = Typist::Parser->parse('Int');
    my $nt = Typist::Type::Newtype->new('UserId', $inner);

    ok  $nt->is_newtype, 'is_newtype';
    is  $nt->name, 'UserId', 'name';
    is  $nt->to_string, 'UserId', 'to_string';
    ok  $nt->inner->is_atom, 'inner is atom';

    my $nt2 = Typist::Type::Newtype->new('UserId', $inner);
    ok  $nt->equals($nt2), 'same-name newtypes are equal';

    my $nt3 = Typist::Type::Newtype->new('OrderId', $inner);
    ok !$nt->equals($nt3), 'different-name newtypes are not equal';
};

# ── Nominal subtyping ────────────────────────────

subtest 'nominal identity' => sub {
    my $int   = Typist::Parser->parse('Int');
    my $uid   = Typist::Type::Newtype->new('UserId', $int);
    my $uid2  = Typist::Type::Newtype->new('UserId', $int);
    my $oid   = Typist::Type::Newtype->new('OrderId', $int);

    ok  is_sub($uid, $uid2), 'UserId <: UserId';
    ok !is_sub($uid, $oid),  'UserId </: OrderId';
    ok !is_sub($uid, $int),  'UserId </: Int (no structural compat)';
    ok !is_sub($int, $uid),  'Int </: UserId';
};

# ── Contains (runtime check) ────────────────────

subtest 'contains with blessed values' => sub {
    my $inner = Typist::Parser->parse('Int');
    my $nt = Typist::Type::Newtype->new('UserId', $inner);

    my $val = bless \(my $v = 42), 'Typist::Newtype::UserId';
    ok  $nt->contains($val), 'blessed UserId with valid inner';

    my $bad_inner = bless \(my $w = 'hello'), 'Typist::Newtype::UserId';
    ok !$nt->contains($bad_inner), 'blessed UserId with invalid inner';

    my $wrong_type = bless \(my $x = 42), 'Typist::Newtype::OrderId';
    ok !$nt->contains($wrong_type), 'wrong newtype class';

    ok !$nt->contains(42),    'plain scalar not newtype';
    ok !$nt->contains(undef), 'undef not newtype';
};

# ── Registry integration ────────────────────────

subtest 'registry newtype' => sub {
    Typist::Registry->reset;
    my $inner = Typist::Parser->parse('Str');
    my $nt = Typist::Type::Newtype->new('Email', $inner);
    Typist::Registry->register_newtype('Email', $nt);

    my $looked = Typist::Registry->lookup_newtype('Email');
    ok $looked && $looked->is_newtype, 'lookup_newtype';
    is $looked->name, 'Email', 'name from registry';

    # lookup_type should find newtypes
    my $from_lookup = Typist::Registry->lookup_type('Email');
    ok $from_lookup && $from_lookup->is_newtype, 'lookup_type finds newtype';
};

# ── Substitute / free_vars ───────────────────────

subtest 'substitute and free_vars' => sub {
    my $var_t = Typist::Type::Var->new('T');
    my $nt = Typist::Type::Newtype->new('Wrapper', $var_t);

    my @fv = $nt->free_vars;
    is_deeply [sort @fv], ['T'], 'free_vars from inner';

    my $int = Typist::Parser->parse('Int');
    my $substituted = $nt->substitute(+{ T => $int });
    ok $substituted->is_newtype, 'substituted is still newtype';
    is $substituted->name, 'Wrapper', 'name preserved';
    ok $substituted->inner->is_atom && $substituted->inner->name eq 'Int',
        'inner substituted';
};

done_testing;
