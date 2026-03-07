package Typist;
use v5.40;

our $VERSION = '0.01';
our $RUNTIME     = $ENV{TYPIST_RUNTIME}     ? 1 : 0;
our $CHECK_QUIET = $ENV{TYPIST_CHECK_QUIET} ? 1 : 0;

# Core runtime — always needed
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
use Typist::Effect;
use Typist::TypeClass;
use Typist::Parser;
use Typist::Registry;
use Typist::Handler;
use Typist::Error;
use Typist::Error::Global;
use Typist::DSL;

# Deferred — loaded on first :sig() or in CHECK phase
# Typist::Kind, Typist::KindChecker, Typist::Subtype, Typist::Inference
# Typist::Attribute (has its own internal require chain)
# Typist::Static::Checker (CHECK only)
require Typist::Attribute;

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
    # Install only once; restored in CHECK after all attributes are processed.
    unless ($Typist::_WARN_INSTALLED) {
        $Typist::_WARN_ORIG = $SIG{__WARN__};
        $SIG{__WARN__} = sub {
            return if $_[0] =~ /attribute may clash with future reserved word/;
            if ($Typist::_WARN_ORIG) { $Typist::_WARN_ORIG->(@_) }
            else                     { warn $_[0] }
        };
        $Typist::_WARN_INSTALLED = 1;
    }

    for my $arg (@args) {
        if    ($arg eq '-runtime') { $Typist::RUNTIME = 1 }
        elsif ($arg =~ /\A[A-Z]/) {
            die "Typist: DSL names cannot be imported via 'use Typist'. "
              . "Use 'use Typist::DSL qw($arg)' instead (at $caller)\n";
        }
    }

    # Runtime enforcement needs Inference/Subtype for constructor validation
    if ($Typist::RUNTIME) {
        require Typist::Inference;
        require Typist::Subtype;
    }

    # Track this package
    Typist::Registry->register_package($caller);

    # Install attribute handlers
    Typist::Attribute->install($caller);

    # Export core functions into caller's namespace.
    # Functions that install symbols into caller receive $caller explicitly.
    no strict 'refs';
    *{"${caller}::typedef"}   = sub ($name, $expr) {
        Typist::Registry::typedef($name, $expr);
        Typist::Registry->set_defined_in($name, $caller);
    };
    *{"${caller}::newtype"}   = sub ($name, $expr) {
        Typist::Definition::_newtype($caller, $name, $expr);
        Typist::Registry->set_defined_in($name, $caller);
    };
    *{"${caller}::typeclass"} = sub ($name, $var, $methods) {
        Typist::Definition::_typeclass($caller, $name, $var, $methods);
        Typist::Registry->set_defined_in($name, $caller);
    };
    *{"${caller}::instance"}  = \&Typist::Definition::_instance;
    *{"${caller}::datatype"}  = sub ($name_spec, %variants) {
        Typist::Algebra::_datatype($caller, $name_spec, %variants);
        my ($base_name) = $name_spec =~ /\A(\w+)/;
        Typist::Registry->set_defined_in($base_name, $caller) if $base_name;
    };
    *{"${caller}::enum"}      = sub ($name, @tags) {
        Typist::Algebra::_enum($caller, $name, @tags);
        Typist::Registry->set_defined_in($name, $caller);
    };
    *{"${caller}::match"}     = \&Typist::Algebra::_match;
    *{"${caller}::struct"}    = sub ($name, @fields) {
        Typist::StructDef::_struct($name, $caller, @fields);
        my ($base_name) = $name =~ /\A(\w+)/;
        Typist::Registry->set_defined_in($base_name, $caller) if $base_name;
    };
    *{"${caller}::effect"}    = sub ($name, @rest) {
        Typist::EffectDef::_effect($name, @rest);
        Typist::Registry->set_defined_in($name, $caller);
    };
    *{"${caller}::handle"}    = \&Typist::EffectDef::_handle;
    *{"${caller}::protocol"}  = \&Typist::EffectDef::_make_protocol;
    *{"${caller}::declare"}   = \&Typist::External::_declare;
    *{"${caller}::optional"}  = \&Typist::DSL::optional;

}

CHECK {
    Typist::Error::Global->reset;

    # 0. Ensure Prelude effects (IO/Exn/Decl) + CORE builtins are in the default
    #    Registry so CHECK-phase analysis can resolve them.  Idempotent.
    require Typist::Prelude;
    Typist::Prelude->install(Typist::Registry->_default);

    # 1. Structural checks on global Registry (alias cycles, free vars, bounds, kinds)
    require Typist::Static::Checker;
    Typist::Static::Checker->new->analyze;

    # 2. Full static analysis per loaded file (TypeChecker + EffectChecker)
    #    Skipped when CHECK_QUIET — typist-lsp provides the same diagnostics.
    _check_analyze() unless $CHECK_QUIET;

    if (Typist::Error::Global->has_errors && !$CHECK_QUIET) {
        warn Typist::Error::Global->report;
    }

    # Restore original warn handler — attribute processing is complete.
    if ($Typist::_WARN_INSTALLED) {
        if ($Typist::_WARN_ORIG) { $SIG{__WARN__} = $Typist::_WARN_ORIG }
        else                     { delete $SIG{__WARN__} }
        $Typist::_WARN_INSTALLED = 0;
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

Define a nominal type wrapper. With C<-runtime>, the constructor validates
values against the inner type at creation time. Use C<< ${Name}::coerce($val) >>
to extract the inner value.

=head2 struct

    struct Person => (name => 'Str', age => 'Int');

Define a nominal struct type with a constructor, field accessors,
and immutable derive via C<< ${Name}::derive($obj, field => val) >>.
Use C<optional(field =E<gt> Type)> for optional fields (flattened into the field list).

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
