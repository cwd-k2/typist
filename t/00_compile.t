use v5.40;
use Test::More;

my @modules = qw(
    Typist
    Typist::Type
    Typist::Type::Atom
    Typist::Type::Param
    Typist::Type::Union
    Typist::Type::Intersection
    Typist::Type::Func
    Typist::Type::Struct
    Typist::Type::Var
    Typist::Type::Alias
    Typist::Parser
    Typist::Registry
    Typist::Subtype
    Typist::Inference
    Typist::Attribute
    Typist::Checker
    Typist::Error
    Typist::Tie::Scalar
);

for my $mod (@modules) {
    require_ok($mod =~ s{::}{/}gr . '.pm');
}

done_testing;
