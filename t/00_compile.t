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
    Typist::Type::Record
    Typist::Type::Var
    Typist::Type::Alias
    Typist::Type::Literal
    Typist::Type::Newtype
    Typist::Type::Data
    Typist::Type::Row
    Typist::Type::Eff
    Typist::Effect
    Typist::Handler
    Typist::Static::EffectChecker
    Typist::Parser
    Typist::Transform
    Typist::TypeClass
    Typist::Kind
    Typist::KindChecker
    Typist::Registry
    Typist::Subtype
    Typist::Inference
    Typist::Attribute
    Typist::Static::Checker
    Typist::Error
    Typist::Error::Global
    Typist::DSL
    Typist::Tie::Scalar
    Typist::Static::Infer
    Typist::Static::Extractor
    Typist::Static::TypeChecker
    Typist::Static::Analyzer
    Typist::LSP
    Typist::LSP::Transport
    Typist::LSP::Server
    Typist::LSP::Workspace
    Typist::LSP::Document
    Typist::LSP::Hover
    Typist::LSP::Completion
    Typist::LSP::CodeAction
    Typist::LSP::Logger
    Typist::LSP::SemanticTokens
    Typist::Prelude
    Typist::Static::Registration
    Typist::Static::Unify
    Typist::Struct::Base
    Typist::Type::Fold
    Typist::Type::Quantified
    Typist::Type::Struct
);

for my $mod (@modules) {
    require_ok($mod =~ s{::}{/}gr . '.pm');
}

done_testing;
