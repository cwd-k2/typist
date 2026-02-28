use v5.40;
use Test::More;
use lib 'lib';
use Typist::Parser;
use Typist::Subtype;
use Typist::Registry;
use Typist::Type::Data;
use Typist::Type::Var;
use Typist::Type::Atom;

sub is_sub { Typist::Subtype->is_subtype(@_) }

# ── Type node basics ─────────────────────────────

subtest 'data type node' => sub {
    my $int = Typist::Type::Atom->new('Int');
    my $variants = +{
        Circle    => [$int],
        Rectangle => [$int, $int],
        Point     => [],
    };
    my $dt = Typist::Type::Data->new('Shape', $variants);

    ok  $dt->is_data, 'is_data';
    is  $dt->name, 'Shape', 'name';
    ok !$dt->is_atom,    'not is_atom';
    ok !$dt->is_newtype, 'not is_newtype';

    # to_string: variants sorted alphabetically
    my $str = $dt->to_string;
    like $str, qr/Circle\(Int\)/,           'to_string contains Circle(Int)';
    like $str, qr/Point/,                   'to_string contains Point';
    like $str, qr/Rectangle\(Int, Int\)/,   'to_string contains Rectangle(Int, Int)';
    # Check ordering (sorted)
    like $str, qr/Circle.+Point.+Rectangle/, 'to_string alphabetical order';
};

# ── Equality ─────────────────────────────────────

subtest 'equality' => sub {
    my $int = Typist::Type::Atom->new('Int');
    my $dt1 = Typist::Type::Data->new('Shape', +{ Circle => [$int] });
    my $dt2 = Typist::Type::Data->new('Shape', +{ Circle => [$int] });
    my $dt3 = Typist::Type::Data->new('Color', +{ Red => [] });

    ok  $dt1->equals($dt2), 'same-name data types are equal';
    ok !$dt1->equals($dt3), 'different-name data types are not equal';
    ok !$dt1->equals($int), 'data type not equal to atom';
};

# ── Nominal subtyping ────────────────────────────

subtest 'nominal identity' => sub {
    my $int = Typist::Type::Atom->new('Int');
    my $shape1 = Typist::Type::Data->new('Shape', +{ Circle => [$int] });
    my $shape2 = Typist::Type::Data->new('Shape', +{ Circle => [$int] });
    my $color  = Typist::Type::Data->new('Color', +{ Red => [] });

    ok  is_sub($shape1, $shape2), 'Shape <: Shape';
    ok !is_sub($shape1, $color),  'Shape </: Color';
    ok !is_sub($shape1, $int),    'Shape </: Int';
    ok !is_sub($int, $shape1),    'Int </: Shape';

    # Any is supertype of everything
    my $any = Typist::Type::Atom->new('Any');
    ok  is_sub($shape1, $any),    'Shape <: Any';
};

# ── Contains (runtime check) ────────────────────

subtest 'contains' => sub {
    my $int = Typist::Type::Atom->new('Int');
    my $str = Typist::Type::Atom->new('Str');
    my $dt = Typist::Type::Data->new('Shape', +{
        Circle    => [$int],
        Rectangle => [$int, $int],
        Point     => [],
    });

    # Correctly tagged and typed
    my $circle = bless +{ _tag => 'Circle', _values => [5] }, 'Typist::Data::Shape';
    ok $dt->contains($circle), 'Circle(5) is contained in Shape';

    my $rect = bless +{ _tag => 'Rectangle', _values => [3, 4] }, 'Typist::Data::Shape';
    ok $dt->contains($rect), 'Rectangle(3, 4) is contained in Shape';

    my $point = bless +{ _tag => 'Point', _values => [] }, 'Typist::Data::Shape';
    ok $dt->contains($point), 'Point is contained in Shape';

    # Wrong tag name
    my $bad_tag = bless +{ _tag => 'Triangle', _values => [1] }, 'Typist::Data::Shape';
    ok !$dt->contains($bad_tag), 'unknown tag not contained';

    # Wrong class
    my $wrong_class = bless +{ _tag => 'Circle', _values => [5] }, 'Typist::Data::Color';
    ok !$dt->contains($wrong_class), 'wrong data class not contained';

    # Wrong arity
    my $bad_arity = bless +{ _tag => 'Circle', _values => [1, 2] }, 'Typist::Data::Shape';
    ok !$dt->contains($bad_arity), 'wrong arity not contained';

    # Wrong inner type
    my $bad_type = bless +{ _tag => 'Circle', _values => ['hello'] }, 'Typist::Data::Shape';
    ok !$dt->contains($bad_type), 'wrong inner type not contained';

    # Plain scalar not contained
    ok !$dt->contains(42),    'plain scalar not data value';
    ok !$dt->contains(undef), 'undef not data value';
};

# ── Constructor functions ─────────────────────────

subtest 'constructors via _datatype' => sub {
    Typist::Registry->reset;

    # Simulate what Typist.pm _datatype does (without use Typist to avoid CHECK)
    require Typist::Type::Data;
    require Typist::Parser;

    my %variants_raw = (
        Circle    => '(Int)',
        Rectangle => '(Int, Int)',
        Point     => '',
    );
    my %parsed_variants;
    for my $tag (keys %variants_raw) {
        my $spec = $variants_raw{$tag};
        my @types;
        if (defined $spec && $spec =~ /\S/) {
            my $inner = $spec;
            $inner =~ s/\A\(\s*//;
            $inner =~ s/\s*\)\z//;
            @types = map { Typist::Parser->parse($_) } split /\s*,\s*/, $inner;
        }
        $parsed_variants{$tag} = \@types;

        # Install constructor into current package
        my @captured = @types;
        my $tag_copy = $tag;
        no strict 'refs';
        *{"main::${tag_copy}"} = sub (@args) {
            die("${tag_copy}(): expected "
                . scalar(@captured)
                . " arguments, got "
                . scalar(@args) . "\n")
                unless @args == @captured;
            for my $i (0 .. $#captured) {
                die("${tag_copy}(): argument "
                    . ($i + 1)
                    . " expected "
                    . $captured[$i]->to_string
                    . ", got $args[$i]\n")
                    unless $captured[$i]->contains($args[$i]);
            }
            bless +{ _tag => $tag_copy, _values => \@args }, 'Typist::Data::Shape';
        };
    }

    my $data_type = Typist::Type::Data->new('Shape', \%parsed_variants);
    Typist::Registry->register_datatype('Shape', $data_type);

    # Successful construction
    my $c = main::Circle(5);
    is ref($c), 'Typist::Data::Shape', 'Circle blessed into correct class';
    is $c->{_tag}, 'Circle', 'tag is Circle';
    is_deeply $c->{_values}, [5], 'values are [5]';
    ok $data_type->contains($c), 'data type contains constructed value';

    my $r = main::Rectangle(3, 4);
    is ref($r), 'Typist::Data::Shape', 'Rectangle blessed into correct class';
    is $r->{_tag}, 'Rectangle', 'tag is Rectangle';
    is_deeply $r->{_values}, [3, 4], 'values are [3, 4]';

    my $p = main::Point();
    is ref($p), 'Typist::Data::Shape', 'Point blessed into correct class';
    is $p->{_tag}, 'Point', 'tag is Point';
    is_deeply $p->{_values}, [], 'values are []';

    # Arity mismatch
    eval { main::Circle(1, 2) };
    like $@, qr/expected 1 arguments, got 2/, 'arity mismatch caught';

    eval { main::Rectangle(1) };
    like $@, qr/expected 2 arguments, got 1/, 'arity mismatch caught (too few)';

    # Type mismatch
    eval { main::Circle('hello') };
    like $@, qr/argument 1 expected Int/, 'type mismatch caught';
};

# ── Registry integration ────────────────────────

subtest 'registry datatype' => sub {
    Typist::Registry->reset;
    my $int = Typist::Type::Atom->new('Int');
    my $dt = Typist::Type::Data->new('Shape', +{ Circle => [$int] });
    Typist::Registry->register_datatype('Shape', $dt);

    my $looked = Typist::Registry->lookup_datatype('Shape');
    ok $looked && $looked->is_data, 'lookup_datatype finds data type';
    is $looked->name, 'Shape', 'name from registry';

    # lookup_type should find datatypes
    my $from_lookup = Typist::Registry->lookup_type('Shape');
    ok $from_lookup && $from_lookup->is_data, 'lookup_type finds datatype';

    # has_alias recognizes datatypes
    ok Typist::Registry->has_alias('Shape'), 'has_alias includes datatypes';
};

# ── Substitute / free_vars ───────────────────────

subtest 'substitute and free_vars' => sub {
    my $var_t = Typist::Type::Var->new('T');
    my $int   = Typist::Type::Atom->new('Int');
    my $dt = Typist::Type::Data->new('Container', +{
        Leaf  => [$var_t],
        Empty => [],
    });

    my @fv = sort $dt->free_vars;
    is_deeply \@fv, ['T'], 'free_vars from variant types';

    my $substituted = $dt->substitute(+{ T => $int });
    ok $substituted->is_data, 'substituted is still data type';
    is $substituted->name, 'Container', 'name preserved';

    my @leaf_types = $substituted->variants->{Leaf}->@*;
    is scalar @leaf_types, 1, 'Leaf has one type';
    ok $leaf_types[0]->is_atom && $leaf_types[0]->name eq 'Int',
        'type variable substituted to Int';

    my @empty_types = $substituted->variants->{Empty}->@*;
    is scalar @empty_types, 0, 'Empty still has no types';
};

# ── Fold integration ────────────────────────────

subtest 'fold map_type and walk' => sub {
    require Typist::Type::Fold;
    my $var_t = Typist::Type::Var->new('T');
    my $int   = Typist::Type::Atom->new('Int');
    my $dt = Typist::Type::Data->new('Box', +{
        Full  => [$var_t],
        Empty => [],
    });

    # map_type: substitute T -> Int
    my $mapped = Typist::Type::Fold->map_type($dt, sub ($node) {
        return $int if $node->is_var && $node->name eq 'T';
        $node;
    });
    ok $mapped->is_data, 'mapped is data';
    my @full_types = $mapped->variants->{Full}->@*;
    ok $full_types[0]->is_atom && $full_types[0]->name eq 'Int',
        'map_type substituted T -> Int in variant';

    # walk: collect all visited node types
    my @visited;
    Typist::Type::Fold->walk($dt, sub ($node) {
        push @visited, ref $node;
    });
    ok(scalar @visited >= 2, 'walk visited data node and children');
    ok((grep { $_ eq 'Typist::Type::Data' } @visited), 'walk visited Data node');
    ok((grep { $_ eq 'Typist::Type::Var' } @visited),  'walk visited Var child');
};

# ── Merge integration ────────────────────────────

subtest 'registry merge' => sub {
    my $reg1 = Typist::Registry->new;
    my $reg2 = Typist::Registry->new;

    my $int = Typist::Type::Atom->new('Int');
    my $dt = Typist::Type::Data->new('Shape', +{ Circle => [$int] });
    $reg2->register_datatype('Shape', $dt);

    $reg1->merge($reg2);
    my $looked = $reg1->lookup_datatype('Shape');
    ok $looked && $looked->is_data, 'merge carries datatypes';
};

# ── Extractor integration ────────────────────────

subtest 'extractor recognizes datatype' => sub {
    require Typist::Static::Extractor;

    my $source = <<'PERL';
use v5.40;
BEGIN {
    datatype Shape =>
        Circle    => '(Int)',
        Rectangle => '(Int, Int)';
}
PERL

    my $extracted = Typist::Static::Extractor->extract($source);
    ok exists $extracted->{datatypes}{Shape}, 'datatype Shape extracted';
    my $info = $extracted->{datatypes}{Shape};
    is $info->{variants}{Circle},    '(Int)',      'Circle variant spec';
    is $info->{variants}{Rectangle}, '(Int, Int)', 'Rectangle variant spec';
    ok defined $info->{line}, 'line number captured';
};

done_testing;
