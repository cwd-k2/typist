package Typist;
use v5.40;

our $VERSION = '0.01';
our $RUNTIME     = $ENV{TYPIST_RUNTIME}     ? 1 : 0;
our $CHECK_QUIET = $ENV{TYPIST_CHECK_QUIET} ? 1 : 0;

use Typist::Type;
use Typist::Type::Atom;
use Typist::Type::Param;
use Typist::Type::Union;
use Typist::Type::Intersection;
use Typist::Type::Func;
use Typist::Type::Record;
use Typist::Type::Var;
use Typist::Type::Alias;
use Typist::Type::Literal;
use Typist::Type::Newtype;
use Typist::Type::Row;
use Typist::Type::Eff;
use Typist::Type::Data;
use Typist::Type::Struct;
use Typist::Struct::Base;
use Typist::Newtype::Base;
use Typist::Effect;
use Typist::TypeClass;
use Typist::Kind;
use Typist::KindChecker;
use Typist::Parser;
use Typist::Registry;
use Typist::Subtype;
use Typist::Inference;
use Typist::Attribute;
use Typist::Handler;
use Typist::Static::Checker;
use Typist::Error;
use Typist::Error::Global;
use Typist::DSL;

# Submodules — decomposed from Typist.pm for maintainability.
# Each receives $caller explicitly where symbol installation is needed.
use Typist::Definition;
use Typist::Algebra;
use Typist::StructDef;
use Typist::EffectDef;
use Typist::External;

sub import ($class, @args) {
    my $caller = caller;

    # Suppress "attribute may clash with future reserved word" for :sig
    my $prev_warn = $SIG{__WARN__};
    $SIG{__WARN__} = sub {
        return if $_[0] =~ /attribute may clash with future reserved word/;
        if ($prev_warn) { $prev_warn->(@_) }
        else            { warn $_[0] }
    };

    my @dsl_names;
    for my $arg (@args) {
        if    ($arg eq '-runtime') { $Typist::RUNTIME = 1 }
        elsif ($arg =~ /\A[A-Z]/ || $arg eq 'optional') { push @dsl_names, $arg }
    }

    # Track this package
    Typist::Registry->register_package($caller);

    # Install attribute handlers
    Typist::Attribute->install($caller);

    # Export core functions into caller's namespace.
    # Functions that install symbols into caller receive $caller explicitly.
    no strict 'refs';
    *{"${caller}::typedef"}   = \&Typist::Registry::typedef;
    *{"${caller}::newtype"}   = sub ($name, $expr) { Typist::Definition::_newtype($caller, $name, $expr) };
    *{"${caller}::typeclass"} = sub ($name, $var, $methods) { Typist::Definition::_typeclass($caller, $name, $var, $methods) };
    *{"${caller}::instance"}  = \&Typist::Definition::_instance;
    *{"${caller}::datatype"}  = sub ($name_spec, %variants) { Typist::Algebra::_datatype($caller, $name_spec, %variants) };
    *{"${caller}::enum"}      = sub ($name, @tags) { Typist::Algebra::_enum($caller, $name, @tags) };
    *{"${caller}::match"}     = \&Typist::Algebra::_match;
    *{"${caller}::struct"}    = sub ($name, @fields) { Typist::StructDef::_struct($name, $caller, @fields) };
    *{"${caller}::effect"}    = \&Typist::EffectDef::_effect;
    *{"${caller}::handle"}    = \&Typist::EffectDef::_handle;
    *{"${caller}::protocol"}  = \&Typist::EffectDef::_make_protocol;
    *{"${caller}::declare"}   = \&Typist::External::_declare;

    # Selective DSL re-export
    if (@dsl_names) {
        my $map = Typist::DSL->export_map;
        for my $name (@dsl_names) {
            die "Typist: unknown export '$name'\n" unless exists $map->{$name};
            *{"${caller}::${name}"} = $map->{$name};
        }
    }
}

CHECK {
    Typist::Error::Global->reset;

    # 0. Ensure Prelude effects (IO/Exn/Decl) + CORE builtins are in the default
    #    Registry so CHECK-phase analysis can resolve them.  Idempotent.
    require Typist::Prelude;
    Typist::Prelude->install(Typist::Registry->_default);

    # 1. Structural checks on global Registry (alias cycles, free vars, bounds, kinds)
    Typist::Static::Checker->new->analyze;

    # 2. Full static analysis per loaded file (TypeChecker + EffectChecker)
    #    Skipped when CHECK_QUIET — typist-lsp provides the same diagnostics.
    _check_analyze() unless $CHECK_QUIET;

    if (Typist::Error::Global->has_errors && !$CHECK_QUIET) {
        warn Typist::Error::Global->report;
    }
}

# ── CHECK-Phase Static Analysis ──────────────────

sub _check_analyze () {
    require Typist::Static::Analyzer;

    my $ws_registry = Typist::Registry->_default;

    for my $pkg (Typist::Registry->all_packages) {
        my $file   = _package_to_file($pkg) // next;
        my $source = _slurp($file)          // next;

        my $result = eval {
            Typist::Static::Analyzer->analyze($source,
                workspace_registry => $ws_registry,
                file               => $file,
            );
        };
        next if $@;

        for my $diag ($result->{diagnostics}->@*) {
            Typist::Error::Global->collect(
                kind    => $diag->{kind},
                message => $diag->{message},
                file    => $diag->{file} // $file,
                line    => $diag->{line} // 0,
            );
        }
    }
}

sub _package_to_file ($pkg) {
    return $0 if $pkg eq 'main' && -f $0;
    my $path = $pkg =~ s|::|/|gr;
    $INC{"${path}.pm"};
}

sub _slurp ($path) {
    open my $fh, '<', $path or return undef;
    local $/;
    scalar readline $fh;
}

1;

__END__

=head1 NAME

Typist - A static-first type system for Perl 5

=head1 SYNOPSIS

    use Typist;
    use Typist::DSL;

    # Type aliases
    BEGIN {
        typedef Name => Str;
    }

    # Typed variables
    my $count :sig(Int) = 0;

    # Typed subroutines
    sub add :sig((Int, Int) -> Int) ($a, $b) {
        $a + $b;
    }

    # Generics with bounded quantification
    sub max_of :sig(<T: Num>(T, T) -> T) ($a, $b) {
        $a > $b ? $a : $b;
    }

=head1 DESCRIPTION

Typist brings static type annotations to Perl through the standard attribute
syntax C<:sig(...)>. Errors are caught at compile time (CHECK phase) and
via the LSP server, with zero runtime overhead by default.

    use Typist;            # Static-only (default)
    use Typist -runtime;   # Enable runtime enforcement

=head1 EXPORTS

The following are exported into the caller's namespace:

=head2 typedef

    typedef Name => Str;

Define a type alias. The right-hand side is a type expression string
or a L<Typist::Type> object.

=head2 newtype

    newtype UserId => 'Int';

Define a nominal type with boundary enforcement. Constructor validates
values at creation time. Use C<< $val->base >> (L<Typist::Newtype::Base>)
to extract the inner value.

=head2 struct

    struct Person => (name => 'Str', age => 'Int');

Define a nominal struct type with a constructor, field accessors,
and immutable update via C<< $obj->with(field => val) >>.
Use C<optional(Type)> for optional fields.

=head2 datatype

    datatype Shape => Circle => '(Int)', Rectangle => '(Int, Int)';

Define an algebraic data type (tagged union) with constructors
installed into the caller's namespace.

=head2 enum

    enum Color => qw(Red Green Blue);

Define a nullary-only ADT (pure enumeration).
Sugar for C<datatype> with all zero-argument variants.

=head2 match

    match $value, Tag => sub (...) { ... }, _ => sub { ... };

Pattern match on an ADT value. Dispatches on C<_tag> and splats C<_values>
into handlers. C<_> is the optional fallback arm.

=head2 handle

    handle { BODY } Effect => +{ op => sub { ... } };

Install scoped effect handlers, execute BODY, and guarantee cleanup.
No comma after the block (same rule as C<map>/C<grep>).

=head2 typeclass

    typeclass Show => T, +{ show => '(T) -> Str' };

Define a type class with method signatures. Methods are installed as
qualified dispatch subs into the caller's namespace.

=head2 instance

    instance Show => Int, +{ show => sub ($x) { "$x" } };

Provide a type class instance. Validates method completeness
against the class definition and checks superclass instances.

=head2 effect

    effect Console => +{ log => '(Str) -> Void' };

Define an algebraic effect with named operations. Operations are
auto-installed as qualified subs (e.g. C<< Console::log(@args) >>).

With protocol (stateful effects):

    effect DB => qw/Connected Authed/ => +{
        connect => protocol('(Str) -> Void', '* -> Connected'),
        query   => protocol('(Str) -> Str',  'Authed -> Authed'),
    };

=head2 protocol

    protocol('(Str) -> Void', '* -> Connected')

Inline operation definition with state transition for effect protocols.
First argument is the type signature, second is the state transition.

=head2 declare

    declare say => '(Str) -> Void ![Console]';

Annotate an external function's type signature. Overrides
L<Typist::Prelude> entries for the declared name.

=head1 ENVIRONMENT

=over 4

=item C<TYPIST_RUNTIME>

Set to C<1> to enable runtime type enforcement.

=item C<TYPIST_CHECK_QUIET>

Set to C<1> to suppress CHECK-phase diagnostics (use when the LSP server
provides diagnostics).

=back

=head1 SEE ALSO

L<Typist::DSL> for type constructors and DSL syntax.

See F<docs/type-system.md> and F<docs/architecture.md> for detailed reference.

=head1 LICENSE

MIT License.

=cut
