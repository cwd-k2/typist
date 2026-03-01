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

    is  $dt->to_string, 'Shape', 'to_string is base name';

    # to_string_full: variants sorted alphabetically
    my $full = $dt->to_string_full;
    like $full, qr/Circle\(Int\)/,           'to_string_full contains Circle(Int)';
    like $full, qr/Point/,                   'to_string_full contains Point';
    like $full, qr/Rectangle\(Int, Int\)/,   'to_string_full contains Rectangle(Int, Int)';
    like $full, qr/Circle.+Point.+Rectangle/, 'to_string_full alphabetical order';
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

# ── Parameterized data type node ─────────────────

subtest 'parameterized data type basics' => sub {
    my $var_t = Typist::Type::Var->new('T');
    my $dt = Typist::Type::Data->new('Option', +{
        Some => [$var_t],
        None => [],
    }, type_params => ['T']);

    ok  $dt->is_data, 'is_data';
    is  $dt->name, 'Option', 'name';
    is_deeply [$dt->type_params], ['T'], 'type_params';
    is_deeply [$dt->type_args],   [],    'type_args empty';
    is  $dt->to_string, 'Option[T]', 'to_string shows params';
};

subtest 'instantiate parameterized type' => sub {
    my $var_t = Typist::Type::Var->new('T');
    my $int   = Typist::Type::Atom->new('Int');
    my $str   = Typist::Type::Atom->new('Str');
    my $dt = Typist::Type::Data->new('Option', +{
        Some => [$var_t],
        None => [],
    }, type_params => ['T']);

    my $opt_int = $dt->instantiate($int);
    is $opt_int->to_string, 'Option[Int]', 'instantiate to_string';
    is_deeply [$opt_int->type_params], ['T'], 'type_params preserved';
    my @args = $opt_int->type_args;
    is scalar @args, 1, 'one type arg';
    ok $args[0]->is_atom && $args[0]->name eq 'Int', 'type arg is Int';

    my $opt_str = $dt->instantiate($str);
    is $opt_str->to_string, 'Option[Str]', 'instantiate Str';
};

subtest 'parameterized contains' => sub {
    my $var_t = Typist::Type::Var->new('T');
    my $int   = Typist::Type::Atom->new('Int');
    my $str   = Typist::Type::Atom->new('Str');
    my $dt = Typist::Type::Data->new('Option', +{
        Some => [$var_t],
        None => [],
    }, type_params => ['T']);

    my $opt_int = $dt->instantiate($int);

    # Some(42) should be contained in Option[Int]
    my $some42 = bless +{ _tag => 'Some', _values => [42] }, 'Typist::Data::Option';
    ok $opt_int->contains($some42), 'Option[Int] contains Some(42)';

    # None() should be contained in Option[Int]
    my $none = bless +{ _tag => 'None', _values => [] }, 'Typist::Data::Option';
    ok $opt_int->contains($none), 'Option[Int] contains None()';

    # Some("hello") should NOT be contained in Option[Int]
    my $some_str = bless +{ _tag => 'Some', _values => ['hello'] }, 'Typist::Data::Option';
    ok !$opt_int->contains($some_str), 'Option[Int] does not contain Some("hello")';

    # Some("hello") should be contained in Option[Str]
    my $opt_str = $dt->instantiate($str);
    ok $opt_str->contains($some_str), 'Option[Str] contains Some("hello")';

    # Uninstantiated Option accepts anything (Var->contains returns 1)
    ok $dt->contains($some42),  'Option[T] contains Some(42)';
    ok $dt->contains($some_str), 'Option[T] contains Some("hello")';
};

subtest 'parameterized equality' => sub {
    my $var_t = Typist::Type::Var->new('T');
    my $int   = Typist::Type::Atom->new('Int');
    my $str   = Typist::Type::Atom->new('Str');
    my $dt = Typist::Type::Data->new('Option', +{
        Some => [$var_t],
        None => [],
    }, type_params => ['T']);

    my $opt_int1 = $dt->instantiate($int);
    my $opt_int2 = $dt->instantiate($int);
    my $opt_str  = $dt->instantiate($str);

    ok  $opt_int1->equals($opt_int2), 'Option[Int] == Option[Int]';
    ok !$opt_int1->equals($opt_str),  'Option[Int] != Option[Str]';
    ok !$opt_int1->equals($dt),       'Option[Int] != Option[T]';
};

subtest 'parameterized subtyping' => sub {
    my $var_t = Typist::Type::Var->new('T');
    my $int   = Typist::Type::Atom->new('Int');
    my $str   = Typist::Type::Atom->new('Str');
    my $num   = Typist::Type::Atom->new('Num');
    my $any   = Typist::Type::Atom->new('Any');
    my $dt = Typist::Type::Data->new('Box', +{
        Wrap => [$var_t],
    }, type_params => ['T']);

    my $box_int = $dt->instantiate($int);
    my $box_num = $dt->instantiate($num);
    my $box_str = $dt->instantiate($str);

    ok  is_sub($box_int, $box_int), 'Box[Int] <: Box[Int]';
    ok  is_sub($box_int, $box_num), 'Box[Int] <: Box[Num] (covariant)';
    ok !is_sub($box_num, $box_int), 'Box[Num] </: Box[Int]';
    ok !is_sub($box_int, $box_str), 'Box[Int] </: Box[Str]';
    ok  is_sub($box_int, $any),     'Box[Int] <: Any';
};

subtest 'parameterized to_string_full' => sub {
    my $var_t = Typist::Type::Var->new('T');
    my $int   = Typist::Type::Atom->new('Int');
    my $dt = Typist::Type::Data->new('Option', +{
        Some => [$var_t],
        None => [],
    }, type_params => ['T']);

    like $dt->to_string_full, qr/Option\[T\]\s*=\s*None \| Some\(T\)/,
        'to_string_full for parameterized type';

    my $opt_int = $dt->instantiate($int);
    like $opt_int->to_string_full, qr/Option\[Int\]\s*=\s*None \| Some\(T\)/,
        'to_string_full for instantiated type (variants keep original params)';
};

subtest 'parameterized substitute' => sub {
    my $var_t = Typist::Type::Var->new('T');
    my $var_u = Typist::Type::Var->new('U');
    my $int   = Typist::Type::Atom->new('Int');
    my $dt = Typist::Type::Data->new('Pair', +{
        MkPair => [$var_t, $var_u],
    }, type_params => ['T', 'U']);

    my $pair_int = $dt->instantiate($int, $var_u);
    is $pair_int->to_string, 'Pair[Int, U]', 'partial instantiation';

    my $fully = $pair_int->substitute(+{ U => $int });
    is $fully->to_string, 'Pair[Int, Int]', 'substitute resolves remaining vars';
};

subtest 'parameterized free_vars' => sub {
    my $var_t = Typist::Type::Var->new('T');
    my $var_u = Typist::Type::Var->new('U');
    my $int   = Typist::Type::Atom->new('Int');
    my $dt = Typist::Type::Data->new('Option', +{
        Some => [$var_t],
        None => [],
    }, type_params => ['T']);

    # T is bound by the declaration, not free
    my @fv = sort $dt->free_vars;
    is_deeply \@fv, [], 'type params are bound, not free';

    my $opt_int = $dt->instantiate($int);
    my @fv2 = sort $opt_int->free_vars;
    is_deeply \@fv2, [], 'instantiated Option[Int] has no free vars';

    # Instantiate with a free variable — U is free
    my $opt_u = $dt->instantiate($var_u);
    my @fv3 = sort $opt_u->free_vars;
    is_deeply \@fv3, ['U'], 'Option[U] has free var U';
};

# ── Parameterized constructor integration ────────

subtest 'parameterized constructors via _datatype' => sub {
    Typist::Registry->reset;

    require Typist::Inference;

    my $name_spec = 'Result[T, E]';
    my ($name, @type_params);
    if ($name_spec =~ /\A(\w+)\[(.+)\]\z/) {
        $name = $1;
        @type_params = map { s/\s//gr } split /,/, $2;
    } else {
        $name = $name_spec;
    }

    my %var_names = map { $_ => 1 } @type_params;
    my %variants_raw = (
        Ok  => '(T)',
        Err => '(E)',
    );
    my %parsed;
    for my $tag (keys %variants_raw) {
        my $spec = $variants_raw{$tag};
        my @types;
        if (defined $spec && $spec =~ /\S/) {
            my $inner = $spec;
            $inner =~ s/\A\(\s*//;
            $inner =~ s/\s*\)\z//;
            @types = map { Typist::Parser->parse($_) } split /\s*,\s*/, $inner;
            @types = map {
                $_->is_alias && $var_names{$_->alias_name}
                    ? Typist::Type::Var->new($_->alias_name)
                    : $_
            } @types;
        }
        $parsed{$tag} = \@types;

        # Install constructor
        my @captured = @types;
        my $tag_copy = $tag;
        my @tp = @type_params;
        no strict 'refs';
        *{"main::${tag_copy}"} = sub (@args) {
            die("${tag_copy}(): expected " . scalar(@captured) . " arguments\n")
                unless @args == @captured;
            my %bindings;
            for my $i (0 .. $#captured) {
                my $f = $captured[$i];
                next unless $f->is_var && $var_names{$f->name};
                $bindings{$f->name} = Typist::Inference->infer_value($args[$i]);
            }
            for my $i (0 .. $#captured) {
                my $exp = %bindings ? $captured[$i]->substitute(\%bindings) : $captured[$i];
                die("${tag_copy}(): type error\n") unless $exp->contains($args[$i]);
            }
            my @ta = map { $bindings{$_} // Typist::Type::Atom->new('Any') } @tp;
            bless +{ _tag => $tag_copy, _values => \@args, _type_args => \@ta },
                'Typist::Data::Result';
        };
    }

    my $dt = Typist::Type::Data->new('Result', \%parsed,
        type_params => \@type_params,
    );
    Typist::Registry->register_datatype('Result', $dt);

    # Construct Ok(42) — infers T=Int, E=Any
    my $ok = main::Ok(42);
    is ref($ok), 'Typist::Data::Result', 'Ok blessed correctly';
    is $ok->{_tag}, 'Ok', 'tag is Ok';
    is_deeply $ok->{_values}, [42], 'values are [42]';
    ok exists $ok->{_type_args}, 'has _type_args';

    # Construct Err("oops") — infers E=Str, T=Any
    my $err = main::Err("oops");
    is $err->{_tag}, 'Err', 'tag is Err';

    # Result[Int, Str] should contain Ok(42)
    my $res_int_str = $dt->instantiate(
        Typist::Type::Atom->new('Int'),
        Typist::Type::Atom->new('Str'),
    );
    ok $res_int_str->contains($ok), 'Result[Int, Str] contains Ok(42)';
    ok $res_int_str->contains($err), 'Result[Int, Str] contains Err("oops")';

    # Result[Str, Str] contains Ok(42) because Str accepts scalars (Perl coercion)
    my $res_str_str = $dt->instantiate(
        Typist::Type::Atom->new('Str'),
        Typist::Type::Atom->new('Str'),
    );
    ok $res_str_str->contains($ok), 'Result[Str, Str] contains Ok(42) (Perl coercion)';

    # Result[Int, Int] should NOT contain Ok([1,2]) since Int rejects refs
    my $ok_ref = bless +{ _tag => 'Ok', _values => [[1, 2]] }, 'Typist::Data::Result';
    my $res_int_int = $dt->instantiate(
        Typist::Type::Atom->new('Int'),
        Typist::Type::Atom->new('Int'),
    );
    ok !$res_int_int->contains($ok_ref), 'Result[Int, Int] does not contain Ok([1,2])';
};

# ── Extractor: parameterized datatype ───────────

subtest 'extractor recognizes parameterized datatype' => sub {
    require Typist::Static::Extractor;

    my $source = <<'PERL';
use v5.40;
BEGIN {
    datatype 'Option[T]' =>
        Some => '(T)',
        None => '()';
}
PERL

    my $extracted = Typist::Static::Extractor->extract($source);
    ok exists $extracted->{datatypes}{Option}, 'parameterized datatype Option extracted';
    my $info = $extracted->{datatypes}{Option};
    is_deeply $info->{type_params}, ['T'], 'type_params extracted';
    is $info->{variants}{Some}, '(T)', 'Some variant spec';
    is $info->{variants}{None}, '()',  'None variant spec';
};

subtest 'extractor: multi-param datatype' => sub {
    require Typist::Static::Extractor;

    my $source = <<'PERL';
use v5.40;
BEGIN {
    datatype 'Either[L, R]' =>
        Left  => '(L)',
        Right => '(R)';
}
PERL

    my $extracted = Typist::Static::Extractor->extract($source);
    ok exists $extracted->{datatypes}{Either}, 'Either extracted';
    is_deeply $extracted->{datatypes}{Either}{type_params}, ['L', 'R'],
        'multi type_params extracted';
};

# ── match expression ─────────────────────────────

subtest 'match dispatches on tag' => sub {
    # Use Typist's _match directly
    require Typist;

    my $circle = bless +{ _tag => 'Circle', _values => [5] }, 'Typist::Data::Shape';
    my $rect   = bless +{ _tag => 'Rectangle', _values => [3, 4] }, 'Typist::Data::Shape';
    my $point  = bless +{ _tag => 'Point', _values => [] }, 'Typist::Data::Shape';

    my $r1 = Typist::_match($circle,
        Circle    => sub ($r)     { 3.14 * $r ** 2 },
        Rectangle => sub ($w, $h) { $w * $h },
        Point     => sub          { 0 },
    );
    is $r1, 3.14 * 25, 'match Circle dispatches correctly';

    my $r2 = Typist::_match($rect,
        Circle    => sub ($r)     { 3.14 * $r ** 2 },
        Rectangle => sub ($w, $h) { $w * $h },
        Point     => sub          { 0 },
    );
    is $r2, 12, 'match Rectangle dispatches correctly';

    my $r3 = Typist::_match($point,
        Circle    => sub ($r)     { 3.14 * $r ** 2 },
        Rectangle => sub ($w, $h) { $w * $h },
        Point     => sub          { 0 },
    );
    is $r3, 0, 'match Point dispatches correctly';
};

subtest 'match fallback arm' => sub {
    require Typist;

    my $circle = bless +{ _tag => 'Circle', _values => [5] }, 'Typist::Data::Shape';

    my $r = Typist::_match($circle,
        Rectangle => sub ($w, $h) { 'rect' },
        _         => sub          { 'other' },
    );
    is $r, 'other', 'fallback _ arm used for unmatched tag';
};

subtest 'match dies on missing arm' => sub {
    require Typist;

    my $circle = bless +{ _tag => 'Circle', _values => [5] }, 'Typist::Data::Shape';

    eval {
        Typist::_match($circle,
            Rectangle => sub { 'rect' },
        );
    };
    like $@, qr/no arm for tag 'Circle'/, 'dies when no matching arm and no fallback';
};

subtest 'match exhaustiveness warning' => sub {
    require Typist;
    Typist::Registry->reset;

    # Register a datatype so exhaustiveness check can find it
    my $int = Typist::Type::Atom->new('Int');
    my $dt = Typist::Type::Data->new('Shape', +{
        Circle    => [$int],
        Rectangle => [$int, $int],
        Point     => [],
    });
    Typist::Registry->register_datatype('Shape', $dt);

    my $circle = bless +{ _tag => 'Circle', _values => [5] }, 'Typist::Data::Shape';

    # Non-exhaustive match should warn
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    Typist::_match($circle,
        Circle => sub ($r) { $r },
    );
    ok @warnings == 1, 'one warning for non-exhaustive match';
    like $warnings[0], qr/non-exhaustive.*missing Point, Rectangle/,
        'warning lists missing variants';

    # Exhaustive match should not warn
    @warnings = ();
    Typist::_match($circle,
        Circle    => sub ($r)     { $r },
        Rectangle => sub ($w, $h) { $w * $h },
        Point     => sub          { 0 },
    );
    is scalar @warnings, 0, 'no warning for exhaustive match';

    # Match with fallback _ should not warn even if not exhaustive
    @warnings = ();
    Typist::_match($circle,
        Circle => sub ($r) { $r },
        _      => sub      { 0 },
    );
    is scalar @warnings, 0, 'no warning with fallback arm';
};

subtest 'match dies on non-tagged value' => sub {
    require Typist;

    eval { Typist::_match(+{}, Point => sub { 0 }) };
    like $@, qr/no _tag/, 'dies when value has no _tag';
};

# ── enum syntax ──────────────────────────────────

subtest 'enum creates nullary-only ADT' => sub {
    require Typist;
    Typist::Registry->reset;

    Typist::_enum('Direction', 'North', 'South', 'East', 'West');

    my $dt = Typist::Registry->lookup_datatype('Direction');
    ok $dt && $dt->is_data, 'Direction registered as data type';
    is scalar(keys $dt->variants->%*), 4, '4 variants';

    for my $tag (qw(North South East West)) {
        ok exists $dt->variants->{$tag}, "$tag variant exists";
        is scalar($dt->variants->{$tag}->@*), 0, "$tag is nullary";
    }
};

subtest 'enum constructors work' => sub {
    require Typist;
    Typist::Registry->reset;

    # Install into main:: for testing
    {
        no strict 'refs';
        local $Typist::_enum_caller = 'main';
        my $data_class = 'Typist::Data::TrafficLight';
        my %parsed;
        for my $tag (qw(RedLight YellowLight GreenLight)) {
            $parsed{$tag} = [];
            my $t = $tag;
            *{"main::${t}"} = sub () {
                bless +{ _tag => $t, _values => [] }, $data_class;
            };
        }
        Typist::Registry->register_datatype('TrafficLight',
            Typist::Type::Data->new('TrafficLight', \%parsed));
    }

    my $r = main::RedLight();
    is ref($r), 'Typist::Data::TrafficLight', 'enum value blessed correctly';
    is $r->{_tag}, 'RedLight', 'tag is RedLight';
    is_deeply $r->{_values}, [], 'no values';

    my $dt = Typist::Registry->lookup_datatype('TrafficLight');
    ok $dt->contains($r), 'data type contains enum value';
};

subtest 'enum match with exhaustiveness' => sub {
    require Typist;
    Typist::Registry->reset;

    my %parsed;
    my $data_class = 'Typist::Data::Suit';
    for my $tag (qw(Hearts Diamonds Clubs Spades)) {
        $parsed{$tag} = [];
    }
    Typist::Registry->register_datatype('Suit',
        Typist::Type::Data->new('Suit', \%parsed));

    my $hearts = bless +{ _tag => 'Hearts', _values => [] }, $data_class;

    # Non-exhaustive — should warn
    my @w;
    local $SIG{__WARN__} = sub { push @w, $_[0] };
    Typist::_match($hearts,
        Hearts   => sub { 'red' },
        Diamonds => sub { 'red' },
    );
    ok @w == 1, 'warns on non-exhaustive enum match';
    like $w[0], qr/missing Clubs, Spades/, 'lists missing enum variants';
};

subtest 'extractor recognizes enum' => sub {
    require Typist::Static::Extractor;

    my $source = <<'PERL';
use v5.40;
BEGIN {
    enum Color => qw(Red Green Blue);
}
PERL

    my $extracted = Typist::Static::Extractor->extract($source);
    ok exists $extracted->{datatypes}{Color}, 'enum Color extracted as datatype';
    my $info = $extracted->{datatypes}{Color};
    is_deeply [sort keys $info->{variants}->%*], [qw(Blue Green Red)],
        'all enum variants extracted';
    is $info->{variants}{Red}, '', 'enum variants are nullary';
};

# ── GADT type representation ──────────────────────

subtest 'GADT: is_gadt predicate' => sub {
    my $int  = Typist::Type::Atom->new('Int');
    my $bool = Typist::Type::Atom->new('Bool');
    my $var_a = Typist::Type::Var->new('A');

    # Non-GADT
    my $dt = Typist::Type::Data->new('Shape', +{
        Circle => [$int],
        Point  => [],
    });
    ok !$dt->is_gadt, 'Shape is not GADT';

    # GADT with return_types
    require Typist::Type::Param;
    my $gadt = Typist::Type::Data->new('Expr', +{
        IntLit  => [$int],
        BoolLit => [$bool],
    },
        type_params  => ['A'],
        return_types => +{
            IntLit  => Typist::Type::Param->new('Expr', $int),
            BoolLit => Typist::Type::Param->new('Expr', $bool),
        },
    );
    ok $gadt->is_gadt, 'Expr is GADT';
};

subtest 'GADT: constructor_return_type' => sub {
    my $int  = Typist::Type::Atom->new('Int');
    my $bool = Typist::Type::Atom->new('Bool');
    require Typist::Type::Param;

    my $gadt = Typist::Type::Data->new('Expr', +{
        IntLit  => [$int],
        BoolLit => [$bool],
        Var     => [Typist::Type::Var->new('A')],
    },
        type_params  => ['A'],
        return_types => +{
            IntLit  => Typist::Type::Param->new('Expr', $int),
            BoolLit => Typist::Type::Param->new('Expr', $bool),
        },
    );

    # Explicit return types
    my $intlit_ret = $gadt->constructor_return_type('IntLit');
    ok $intlit_ret->is_param, 'IntLit return is Param';
    is $intlit_ret->to_string, 'Expr[Int]', 'IntLit returns Expr[Int]';

    my $boollit_ret = $gadt->constructor_return_type('BoolLit');
    is $boollit_ret->to_string, 'Expr[Bool]', 'BoolLit returns Expr[Bool]';

    # Var has no explicit return type — gets generic default
    my $var_ret = $gadt->constructor_return_type('Var');
    ok $var_ret->is_data, 'Var return is Data';
    my @ta = $var_ret->type_args;
    is scalar @ta, 1, 'one type arg';
    ok $ta[0]->is_var && $ta[0]->name eq 'A', 'generic default Expr[A]';
};

subtest 'GADT: return_types preserved through substitute' => sub {
    my $int  = Typist::Type::Atom->new('Int');
    my $var_a = Typist::Type::Var->new('A');
    require Typist::Type::Param;

    my $gadt = Typist::Type::Data->new('Expr', +{
        IntLit => [$int],
        Var    => [$var_a],
    },
        type_params  => ['A'],
        return_types => +{
            IntLit => Typist::Type::Param->new('Expr', $int),
        },
    );

    my $subst = $gadt->substitute(+{ A => $int });
    ok $subst->is_gadt, 'substituted is still GADT';
    my $rt = $subst->return_types;
    ok exists $rt->{IntLit}, 'IntLit return_type preserved after substitute';
};

subtest 'GADT: return_types preserved through instantiate' => sub {
    my $int  = Typist::Type::Atom->new('Int');
    my $bool = Typist::Type::Atom->new('Bool');
    require Typist::Type::Param;

    my $gadt = Typist::Type::Data->new('Expr', +{
        IntLit  => [$int],
        BoolLit => [$bool],
    },
        type_params  => ['A'],
        return_types => +{
            IntLit  => Typist::Type::Param->new('Expr', $int),
            BoolLit => Typist::Type::Param->new('Expr', $bool),
        },
    );

    my $inst = $gadt->instantiate($int);
    ok $inst->is_gadt, 'instantiated is still GADT';
    is $inst->to_string, 'Expr[Int]', 'instantiated to_string';
};

subtest 'GADT: to_string_full shows return types' => sub {
    my $int  = Typist::Type::Atom->new('Int');
    my $bool = Typist::Type::Atom->new('Bool');
    require Typist::Type::Param;

    my $gadt = Typist::Type::Data->new('Expr', +{
        IntLit  => [$int],
        BoolLit => [$bool],
    },
        type_params  => ['A'],
        return_types => +{
            IntLit  => Typist::Type::Param->new('Expr', $int),
            BoolLit => Typist::Type::Param->new('Expr', $bool),
        },
    );

    my $str = $gadt->to_string_full;
    like $str, qr/IntLit\(Int\) -> Expr\[Int\]/, 'GADT IntLit shows return type';
    like $str, qr/BoolLit\(Bool\) -> Expr\[Bool\]/, 'GADT BoolLit shows return type';
};

subtest 'GADT: equals compares return_types' => sub {
    my $int  = Typist::Type::Atom->new('Int');
    my $bool = Typist::Type::Atom->new('Bool');
    require Typist::Type::Param;

    my $gadt1 = Typist::Type::Data->new('Expr', +{
        IntLit => [$int],
    },
        type_params  => ['A'],
        return_types => +{
            IntLit => Typist::Type::Param->new('Expr', $int),
        },
    );

    my $gadt2 = Typist::Type::Data->new('Expr', +{
        IntLit => [$int],
    },
        type_params  => ['A'],
        return_types => +{
            IntLit => Typist::Type::Param->new('Expr', $int),
        },
    );

    my $gadt3 = Typist::Type::Data->new('Expr', +{
        IntLit => [$int],
    },
        type_params  => ['A'],
        return_types => +{
            IntLit => Typist::Type::Param->new('Expr', $bool),
        },
    );

    ok  $gadt1->equals($gadt2), 'same return_types are equal';
    ok !$gadt1->equals($gadt3), 'different return_types are not equal';
};

subtest 'GADT: free_vars includes return_types' => sub {
    my $var_a = Typist::Type::Var->new('A');
    my $var_b = Typist::Type::Var->new('B');
    my $int   = Typist::Type::Atom->new('Int');
    require Typist::Type::Param;

    my $gadt = Typist::Type::Data->new('Expr', +{
        Lit => [$int],
    },
        type_params  => ['A'],
        return_types => +{
            Lit => Typist::Type::Param->new('Expr', $var_b),
        },
    );

    my @fv = sort $gadt->free_vars;
    is_deeply \@fv, ['B'], 'B is free (from return_types), A is bound';
};

# ── parse_constructor_spec ────────────────────────

subtest 'parse_constructor_spec: normal ADT' => sub {
    my ($types, $ret) = Typist::Type::Data->parse_constructor_spec('(Int, Str)');
    is scalar @$types, 2, 'two param types';
    ok $types->[0]->is_atom && $types->[0]->name eq 'Int', 'first is Int';
    ok $types->[1]->is_atom && $types->[1]->name eq 'Str', 'second is Str';
    ok !defined $ret, 'no return expr';
};

subtest 'parse_constructor_spec: GADT' => sub {
    my ($types, $ret) = Typist::Type::Data->parse_constructor_spec(
        '(Int) -> Expr[Int]'
    );
    is scalar @$types, 1, 'one param type';
    ok $types->[0]->is_atom && $types->[0]->name eq 'Int', 'param is Int';
    is $ret, 'Expr[Int]', 'return expr captured';
};

subtest 'parse_constructor_spec: empty args' => sub {
    my ($types, $ret) = Typist::Type::Data->parse_constructor_spec('()');
    is scalar @$types, 0, 'no param types';
    ok !defined $ret, 'no return expr';
};

subtest 'parse_constructor_spec: alias→Var promotion' => sub {
    my ($types, $ret) = Typist::Type::Data->parse_constructor_spec(
        '(T)', type_params => ['T']
    );
    is scalar @$types, 1, 'one param type';
    ok $types->[0]->is_var && $types->[0]->name eq 'T', 'T promoted to Var';
};

subtest 'parse_constructor_spec: GADT with type param' => sub {
    my ($types, $ret) = Typist::Type::Data->parse_constructor_spec(
        '(Expr[Bool], Expr[A], Expr[A]) -> Expr[A]',
        type_params => ['A'],
    );
    is scalar @$types, 3, 'three param types';
    is $ret, 'Expr[A]', 'return expr is Expr[A]';
    # Second param should have A promoted to Var inside the Param
    # (but parse_constructor_spec only promotes top-level aliases)
};

subtest 'parse_constructor_spec: blank spec' => sub {
    my ($types, $ret) = Typist::Type::Data->parse_constructor_spec('');
    is scalar @$types, 0, 'no types';
    ok !defined $ret, 'no return';

    ($types, $ret) = Typist::Type::Data->parse_constructor_spec(undef);
    is scalar @$types, 0, 'undef → no types';
};

done_testing;
