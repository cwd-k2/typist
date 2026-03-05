use v5.40;
use Test::More;
use lib 'lib', 't/lib';

use Test::Typist::LSP qw(run_session lsp_request lsp_notification init_shutdown_wrap);

# ── Completion inside :sig( ─────────────────────

subtest 'completion inside :sig(' => sub {
    my $source = "use v5.40;\nsub foo :sig(";

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/completion', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 1, character => length('sub foo :sig(') },
        }),
    ));

    my ($comp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $comp, 'got completion response';
    ok $comp->{result}{items}, 'has items';

    my @labels = map { $_->{label} } @{$comp->{result}{items}};
    ok((grep { $_ eq 'Int' }      @labels), 'Int in completions');
    ok((grep { $_ eq 'Str' }      @labels), 'Str in completions');
    ok((grep { $_ eq 'ArrayRef' } @labels), 'ArrayRef in completions');
};

# ── Completion inside :sig(< ─────────────────

subtest 'completion inside :sig(<' => sub {
    my $source = "use v5.40;\nsub foo :sig(<";

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/completion', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 1, character => length('sub foo :sig(<') },
        }),
    ));

    my ($comp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $comp, 'got completion response';
    ok $comp->{result}{items}, 'has items';

    my @labels = map { $_->{label} } @{$comp->{result}{items}};
    ok((grep { $_ eq 'T' } @labels), 'T in completions');
    ok((grep { $_ eq 'U' } @labels), 'U in completions');
    # Should not include primitives
    ok(!(grep { $_ eq 'Int' } @labels), 'Int not in generic completions');
};

# ── No completion outside type context ───────────

subtest 'no completion outside type context' => sub {
    my $source = "use v5.40;\nmy \$x = ";

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/completion', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 1, character => length('my $x = ') },
        }),
    ));

    my ($comp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $comp, 'got completion response';
    is scalar @{$comp->{result}{items}}, 0, 'no completions outside type context';
};

# ── Completion inside :sig(... ! ────────────────

subtest 'completion inside :sig(... !' => sub {
    my $source = "use v5.40;\nsub foo :sig(() -> Void ! ";

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/completion', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 1, character => length('sub foo :sig(() -> Void ! ') },
        }),
    ));

    my ($comp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $comp, 'got completion response';
    # Should return items (even if empty, no primitives in effect context)
    ok $comp->{result}{items}, 'has items array';
    # Should NOT include type primitives
    my @labels = map { $_->{label} } @{$comp->{result}{items}};
    ok(!(grep { $_ eq 'Int' } @labels), 'Int not in effect completions');
    ok(!(grep { $_ eq 'Str' } @labels), 'Str not in effect completions');
    # Should include Prelude effects (IO, Exn, Decl)
    ok((grep { $_ eq 'IO' }   @labels), 'IO in effect completions (from Prelude)');
    ok((grep { $_ eq 'Exn' }  @labels), 'Exn in effect completions (from Prelude)');
    ok((grep { $_ eq 'Decl' } @labels), 'Decl in effect completions (from Prelude)');
};

# ── Completion inside :sig(<T: — constraint context ──

subtest 'completion inside :sig(<T: ' => sub {
    my $source = "use v5.40;\nsub foo :sig(<T: ";

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/completion', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 1, character => length('sub foo :sig(<T: ') },
        }),
    ));

    my ($comp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $comp, 'got completion response';
    ok $comp->{result}{items}, 'has items';

    # Should not include type primitives or type vars in constraint context
    my @labels = map { $_->{label} } @{$comp->{result}{items}};
    ok(!(grep { $_ eq 'Int' } @labels), 'Int not in constraint completions');
    ok(!(grep { $_ eq 'T' }   @labels), 'T not in constraint completions');
};

# ── Constructor completion in code context ────────

subtest 'constructor completion in code context' => sub {
    # Need workspace with a datatype for constructors to be available.
    # The completion handler returns constructors when no :sig() context is detected.
    # Create a workspace by using a mock workspace setup via Server internals.
    use Typist::LSP::Server;
    use Typist::LSP::Transport;
    use Typist::LSP::Logger;
    use Typist::LSP::Workspace;

    # Set up a workspace with a datatype file
    my $ws = Typist::LSP::Workspace->new;
    my $dt_source = <<'PERL';
use v5.40;
package Shapes;
datatype Shape =>
    Circle    => '(Int)',
    Rectangle => '(Int, Int)';
PERL
    $ws->update_file('/fake/Shapes.pm', $dt_source);

    my @constructors = $ws->all_constructor_names;
    ok(scalar @constructors >= 2, 'workspace has constructor names');
    ok((grep { $_ eq 'Circle' } @constructors), 'Circle in constructors');
    ok((grep { $_ eq 'Rectangle' } @constructors), 'Rectangle in constructors');
};

# ── Code Completion: struct field ────────────────

subtest 'code completion: struct field' => sub {
    use Typist::LSP::Document;
    use Typist::LSP::Completion;
    use Typist::Registry;

    my $source = <<'PERL';
use v5.40;
package TestPkg;
my $point :sig({ x => Int, y => Int }) = +{ x => 1, y => 2 };
$point->{
PERL

    my $doc = Typist::LSP::Document->new(uri => 'file:///test_struct.pm', content => $source);
    my $reg = Typist::Registry->new;
    $doc->analyze(workspace_registry => $reg);

    # Verify context detection
    my $ctx = $doc->code_completion_at(3, length('$point->{'));
    ok $ctx, 'detected struct field context';
    is $ctx->{kind}, 'record_field', 'kind is record_field';
    is $ctx->{var}, '$point', 'var is $point';

    # Verify type resolution
    my $type_str = $doc->resolve_var_type('$point');
    ok $type_str, 'resolved variable type';
    like $type_str, qr/x/, 'type contains field x';

    # Verify completions
    my $items = Typist::LSP::Completion->complete_code($ctx, $doc, $reg);
    ok ref $items eq 'ARRAY', 'items is array';
    ok @$items >= 2, 'at least 2 field completions';

    my @labels = map { $_->{label} } @$items;
    ok((grep { $_ eq 'x' } @labels), 'field x in completions');
    ok((grep { $_ eq 'y' } @labels), 'field y in completions');

    # Verify kind is Field (5)
    for my $item (@$items) {
        is $item->{kind}, 5, "item '$item->{label}' has Field kind";
    }

    # Verify detail contains type info
    my ($x_item) = grep { $_->{label} eq 'x' } @$items;
    like $x_item->{detail}, qr/Int/, 'field x detail contains Int';
};

# ── Code Completion: struct field with prefix ────

subtest 'code completion: struct field with prefix' => sub {
    my $source = <<'PERL';
use v5.40;
package TestPkg2;
my $rec :sig({ name => Str, age => Int, address => Str }) = +{};
$rec->{a
PERL

    my $doc = Typist::LSP::Document->new(uri => 'file:///test_prefix.pm', content => $source);
    my $reg = Typist::Registry->new;
    $doc->analyze(workspace_registry => $reg);

    my $ctx = $doc->code_completion_at(3, length('$rec->{a'));
    ok $ctx, 'detected struct field context with prefix';
    is $ctx->{prefix}, 'a', 'prefix is a';

    my $items = Typist::LSP::Completion->complete_code($ctx, $doc, $reg);
    my @labels = map { $_->{label} } @$items;
    ok((grep { $_ eq 'age' }     @labels), 'age in filtered completions');
    ok((grep { $_ eq 'address' } @labels), 'address in filtered completions');
    ok(!(grep { $_ eq 'name' }   @labels), 'name NOT in filtered completions');
};

# ── Code Completion: struct field with optional fields ──

subtest 'code completion: struct optional fields' => sub {
    my $source = <<'PERL';
use v5.40;
package TestPkg3;
my $user :sig({ name => Str, email? => Str }) = +{ name => "alice" };
$user->{
PERL

    my $doc = Typist::LSP::Document->new(uri => 'file:///test_opt.pm', content => $source);
    my $reg = Typist::Registry->new;
    $doc->analyze(workspace_registry => $reg);

    my $ctx = $doc->code_completion_at(3, length('$user->{'));
    ok $ctx, 'detected context';

    my $items = Typist::LSP::Completion->complete_code($ctx, $doc, $reg);
    my @labels = map { $_->{label} } @$items;
    ok((grep { $_ eq 'name' }  @labels), 'required field name present');
    ok((grep { $_ eq 'email' } @labels), 'optional field email present');

    my ($email) = grep { $_->{label} eq 'email' } @$items;
    like $email->{detail}, qr/optional/, 'optional field marked as optional';
};

# ── Code Completion: method ───────────────────────

subtest 'code completion: method' => sub {
    use Typist::LSP::Workspace;

    # Build a workspace with a package that has methods
    my $ws = Typist::LSP::Workspace->new;
    my $pkg_source = <<'PERL';
use v5.40;
package Counter;

sub new :sig(() -> Counter) ($class) {
    bless +{ count => 0 }, $class;
}

sub increment :sig((Int) -> Void) ($self, $n) {
    $self->{count} += $n;
}

sub get_count :sig(() -> Int) ($self) {
    $self->{count};
}
PERL
    $ws->update_file('/fake/Counter.pm', $pkg_source);

    # Now create a doc that uses $self->
    my $doc_source = <<'PERL';
use v5.40;
package Counter;

sub new :sig(() -> Counter) ($class) {
    bless +{ count => 0 }, $class;
}

sub increment :sig((Int) -> Void) ($self, $n) {
    $self->{count} += $n;
}

sub get_count :sig(() -> Int) ($self) {
    $self->{count};
}

sub reset :sig(() -> Void) ($self) {
    $self->
}
PERL

    my $doc = Typist::LSP::Document->new(uri => 'file:///fake/Counter.pm', content => $doc_source);
    $doc->analyze(workspace_registry => $ws->registry);

    # Verify context detection — $self-> is on line 16 (0-indexed)
    my $ctx = $doc->code_completion_at(16, length('    $self->'));
    ok $ctx, 'detected method context';
    is $ctx->{kind}, 'method', 'kind is method';
    is $ctx->{prefix}, '', 'empty prefix';

    my $items = Typist::LSP::Completion->complete_code($ctx, $doc, $ws->registry);
    ok ref $items eq 'ARRAY', 'items is array';

    my @labels = map { $_->{label} } @$items;
    ok((grep { $_ eq 'increment' } @labels), 'increment in method completions');
    ok((grep { $_ eq 'get_count' } @labels), 'get_count in method completions');

    # Verify kind is Method (2)
    for my $item (@$items) {
        is $item->{kind}, 2, "item '$item->{label}' has Method kind";
    }
};

# ── Code Completion: method with prefix ───────────

subtest 'code completion: method with prefix' => sub {
    my $ws = Typist::LSP::Workspace->new;
    my $pkg_source = <<'PERL';
use v5.40;
package Animal;

sub speak :sig(() -> Str) ($self) { "..." }
sub sleep :sig(() -> Void) ($self) { }
sub eat :sig((Str) -> Void) ($self, $food) { }
PERL
    $ws->update_file('/fake/Animal.pm', $pkg_source);

    my $doc_source = <<'PERL';
use v5.40;
package Animal;

sub speak :sig(() -> Str) ($self) { "..." }
sub sleep :sig(() -> Void) ($self) { }
sub eat :sig((Str) -> Void) ($self, $food) { }

sub run :sig(() -> Void) ($self) {
    $self->s
}
PERL

    my $doc = Typist::LSP::Document->new(uri => 'file:///fake/Animal.pm', content => $doc_source);
    $doc->analyze(workspace_registry => $ws->registry);

    # $self->s is on line 8 (0-indexed)
    my $ctx = $doc->code_completion_at(8, length('    $self->s'));
    ok $ctx, 'detected method context with prefix';
    is $ctx->{prefix}, 's', 'prefix is s';

    my $items = Typist::LSP::Completion->complete_code($ctx, $doc, $ws->registry);
    my @labels = map { $_->{label} } @$items;
    ok((grep { $_ eq 'speak' } @labels), 'speak in filtered completions');
    ok((grep { $_ eq 'sleep' } @labels), 'sleep in filtered completions');
    ok(!(grep { $_ eq 'eat' } @labels), 'eat NOT in filtered completions');
};

# ── Code Completion: effect operation ─────────────

subtest 'code completion: effect operation' => sub {
    my $ws = Typist::LSP::Workspace->new;
    my $eff_source = <<'PERL';
use v5.40;
package Effects;
effect Console => +{
    writeLine => '(Str) -> Void',
    readLine  => '() -> Str',
};
PERL
    $ws->update_file('/fake/Effects.pm', $eff_source);

    my $doc_source = <<'PERL';
use v5.40;
Console::
PERL

    my $doc = Typist::LSP::Document->new(uri => 'file:///test_eff.pm', content => $doc_source);

    # Verify context detection
    my $ctx = $doc->code_completion_at(1, length('Console::'));
    ok $ctx, 'detected effect op context';
    is $ctx->{kind}, 'effect_op', 'kind is effect_op';
    is $ctx->{effect}, 'Console', 'effect is Console';

    my $items = Typist::LSP::Completion->complete_code($ctx, $doc, $ws->registry);
    ok ref $items eq 'ARRAY', 'items is array';
    ok @$items >= 2, 'at least 2 effect ops';

    my @labels = map { $_->{label} } @$items;
    ok((grep { $_ eq 'writeLine' } @labels), 'writeLine in completions');
    ok((grep { $_ eq 'readLine' }  @labels), 'readLine in completions');

    # Verify kind is Method (2)
    for my $item (@$items) {
        is $item->{kind}, 2, "item '$item->{label}' has Method kind";
    }

    # Verify detail contains type info
    my ($wl) = grep { $_->{label} eq 'writeLine' } @$items;
    like $wl->{detail}, qr/Str/, 'writeLine detail contains Str';
};

# ── Code Completion: effect op with prefix ────────

subtest 'code completion: effect op with prefix' => sub {
    my $ws = Typist::LSP::Workspace->new;
    my $eff_source = <<'PERL';
use v5.40;
package Effects2;
effect Storage => +{
    getItem    => '(Str) -> Str',
    setItem    => '(Str, Str) -> Void',
    removeItem => '(Str) -> Void',
};
PERL
    $ws->update_file('/fake/Effects2.pm', $eff_source);

    my $doc_source = "use v5.40;\nStorage::get";
    my $doc = Typist::LSP::Document->new(uri => 'file:///test_eff2.pm', content => $doc_source);

    my $ctx = $doc->code_completion_at(1, length('Storage::get'));
    ok $ctx, 'detected effect op context with prefix';
    is $ctx->{prefix}, 'get', 'prefix is get';

    my $items = Typist::LSP::Completion->complete_code($ctx, $doc, $ws->registry);
    my @labels = map { $_->{label} } @$items;
    ok((grep { $_ eq 'getItem' } @labels), 'getItem in filtered completions');
    ok(!(grep { $_ eq 'setItem' } @labels), 'setItem NOT in filtered completions');
    ok(!(grep { $_ eq 'removeItem' } @labels), 'removeItem NOT in filtered completions');
};

# ── Code Completion context: no false positives ───

subtest 'code completion: context detection edge cases' => sub {
    my $doc = Typist::LSP::Document->new(
        uri => 'file:///edge.pm',
        content => "use v5.40;\nmy \$x = 1;\n",
    );

    # Plain variable assignment should not trigger
    my $ctx = $doc->code_completion_at(1, length('my $x = 1'));
    is $ctx, undef, 'no code context for plain assignment';

    # $var-> without { should not trigger struct field
    my $doc2 = Typist::LSP::Document->new(
        uri => 'file:///edge2.pm',
        content => "use v5.40;\n\$obj->method(",
    );
    $ctx = $doc2->code_completion_at(1, length('$obj->method('));
    is $ctx, undef, 'no code context for method call with parens';
};

# ── type_expr includes forall snippet ──────────────

subtest 'type_expr completion includes forall snippet' => sub {
    require Typist::LSP::Completion;

    my $items = Typist::LSP::Completion->complete('type_expr', [], [], []);
    my @labels = map { $_->{label} } @$items;
    ok((grep { $_ eq 'forall' } @labels), 'forall in type_expr completions');

    my ($forall) = grep { $_->{label} eq 'forall' } @$items;
    is $forall->{insertTextFormat}, 2, 'forall is a snippet';
    like $forall->{insertText}, qr/forall/, 'insert text contains forall';
};

# ── generic completion includes doc-level type vars ──

subtest 'generic completion includes document type vars' => sub {
    require Typist::LSP::Completion;

    my $items = Typist::LSP::Completion->complete(
        'generic', [], [], [], ['A', 'B'],
    );
    my @labels = map { $_->{label} } @$items;
    ok((grep { $_ eq 'A' } @labels), 'A from document in generic completions');
    ok((grep { $_ eq 'B' } @labels), 'B from document in generic completions');
    ok((grep { $_ eq 'T' } @labels), 'T still present as standard type var');
};

# ── constructor names include struct and newtype ─────

subtest 'constructor names include struct and newtype' => sub {
    require Typist::LSP::Workspace;

    my $ws = Typist::LSP::Workspace->new;
    my $source = <<'PERL';
use v5.40;
package Types;
struct Point => (x => 'Int', y => 'Int');
newtype UserId => 'Int';
datatype Shape =>
    Circle => '(Int)';
PERL
    $ws->update_file('/fake/Types.pm', $source);

    my @ctors = $ws->all_constructor_names;
    ok((grep { $_ eq 'Circle' } @ctors), 'Circle from datatype');
    ok((grep { $_ eq 'Point' }  @ctors), 'Point from struct');
    ok((grep { $_ eq 'UserId' } @ctors), 'UserId from newtype');
};

# ── Code Completion: cross-package method ─────────

subtest 'code completion: cross-package struct methods' => sub {
    use Typist::LSP::Workspace;
    use Typist::LSP::Document;
    use Typist::LSP::Completion;

    my $ws = Typist::LSP::Workspace->new;
    my $type_source = <<'PERL';
use v5.40;
package Types;
struct Point => (x => 'Int', y => 'Int');
PERL
    $ws->update_file('/fake/Types.pm', $type_source);

    my $doc_source = <<'PERL';
use v5.40;
my $p :sig(Point) = Point(x => 1, y => 2);
$p->
PERL

    my $doc = Typist::LSP::Document->new(uri => 'file:///test_cross.pm', content => $doc_source);
    $doc->analyze(workspace_registry => $ws->registry);

    my $ctx = $doc->code_completion_at(2, length('$p->'));
    ok $ctx, 'detected method context for $p->';
    is $ctx->{kind}, 'method', 'kind is method';
    is $ctx->{var}, '$p', 'var is $p';

    my $items = Typist::LSP::Completion->complete_code($ctx, $doc, $ws->registry);
    ok ref $items eq 'ARRAY', 'items is array';

    my @labels = map { $_->{label} } @$items;
    ok((grep { $_ eq 'x' }    @labels), 'x in completions');
    ok((grep { $_ eq 'y' }    @labels), 'y in completions');
    ok(!(grep { $_ eq 'with' } @labels), 'with NOT in completions (removed)');
};

# ── Code Completion: match arm ────────────────────

subtest 'code completion: match arm' => sub {
    use Typist::LSP::Workspace;
    use Typist::LSP::Document;
    use Typist::LSP::Completion;

    my $ws = Typist::LSP::Workspace->new;
    my $dt_source = <<'PERL';
use v5.40;
package Shapes;
datatype Shape =>
    Circle    => '(Int)',
    Rectangle => '(Int, Int)';
PERL
    $ws->update_file('/fake/Shapes.pm', $dt_source);

    my $doc_source = <<'PERL';
use v5.40;
my $s :sig(Shape) = Circle(5);
match $s,
PERL

    my $doc = Typist::LSP::Document->new(uri => 'file:///test_match.pm', content => $doc_source);
    $doc->analyze(workspace_registry => $ws->registry);

    my $ctx = $doc->code_completion_at(2, length('match $s, '));
    ok $ctx, 'detected match_arm context';
    is $ctx->{kind}, 'match_arm', 'kind is match_arm';
    is $ctx->{var}, '$s', 'var is $s';

    my $items = Typist::LSP::Completion->complete_code($ctx, $doc, $ws->registry);
    ok ref $items eq 'ARRAY', 'items is array';

    my @labels = map { $_->{label} } @$items;
    ok((grep { $_ eq 'Circle' }    @labels), 'Circle in match arms');
    ok((grep { $_ eq 'Rectangle' } @labels), 'Rectangle in match arms');
    ok((grep { $_ eq '_' }         @labels), '_ fallback in match arms');
};

subtest 'code completion: match arm excludes used arms' => sub {
    my $ws = Typist::LSP::Workspace->new;
    my $dt_source = <<'PERL';
use v5.40;
package Shapes2;
datatype Color => Red => '()', Green => '()', Blue => '()';
PERL
    $ws->update_file('/fake/Shapes2.pm', $dt_source);

    my $doc_source = <<'PERL';
use v5.40;
my $c :sig(Color) = Red();
match $c, Red => sub { "r" },
PERL

    my $doc = Typist::LSP::Document->new(uri => 'file:///test_match2.pm', content => $doc_source);
    $doc->analyze(workspace_registry => $ws->registry);

    my $ctx = $doc->code_completion_at(2, length('match $c, Red => sub { "r" }, '));
    ok $ctx, 'detected match_arm context';
    is_deeply $ctx->{used}, ['Red'], 'Red is already used';

    my $items = Typist::LSP::Completion->complete_code($ctx, $doc, $ws->registry);
    my @labels = map { $_->{label} } @$items;
    ok(!(grep { $_ eq 'Red' }   @labels), 'Red excluded');
    ok((grep { $_ eq 'Green' }  @labels), 'Green still available');
    ok((grep { $_ eq 'Blue' }   @labels), 'Blue still available');
};

done_testing;
