use v5.40;
use Test::More;
use lib 'lib';

use Typist::LSP::Workspace;
use Typist::LSP::Document;
use Typist::LSP::Hover;
use Typist::LSP::Completion;
use Typist::Static::Analyzer;

my $root = 'example/realworld/lib';
plan skip_all => 'realworld example not found' unless -d $root;

# ── Workspace Scan ──────────────────────────────

my $ws = Typist::LSP::Workspace->new(root => $root);
my $reg = $ws->registry;

subtest 'workspace indexes all realworld types' => sub {
    # Aliases from Types.pm
    for my $name (qw(Product Quantity Price Order OrderItem)) {
        ok $reg->has_alias($name), "alias $name registered";
    }

    # Newtypes from Types.pm
    for my $name (qw(ProductId OrderId)) {
        ok $reg->lookup_newtype($name), "newtype $name registered";
    }

    # Effects from Types.pm
    ok $reg->lookup_effect('Logger'), 'effect Logger registered';

    # Functions from Inventory.pm and Order.pm
    ok $reg->lookup_function('Shop::Inventory', 'add_product'),  'add_product registered';
    ok $reg->lookup_function('Shop::Inventory', 'find_product'), 'find_product registered';
    ok $reg->lookup_function('Shop::Inventory', 'in_stock'),     'in_stock registered';
    ok $reg->lookup_function('Shop::Order', 'order_total'),      'order_total registered';
    ok $reg->lookup_function('Shop::Order', 'create_order'),     'create_order registered';
};

# ── Cross-file Diagnostics ──────────────────────

subtest 'cross-file analysis produces no false positives' => sub {
    for my $pm (sort glob("$root/Shop/*.pm")) {
        open my $fh, '<', $pm or die "$pm: $!";
        my $src = do { local $/; <$fh> };
        close $fh;

        my $result = Typist::Static::Analyzer->analyze($src,
            file               => $pm,
            workspace_registry => $reg,
        );

        my @diags = @{$result->{diagnostics}};
        (my $short = $pm) =~ s{.*/}{};
        is scalar @diags, 0, "$short: no diagnostics"
            or diag map { "  L$_->{line} [$_->{kind}] $_->{message}\n" } @diags;
    }
};

# ── Hover on Cross-file Functions ────────────────

subtest 'hover shows cross-file type signatures' => sub {
    my $path = "$root/Shop/Order.pm";
    open my $fh, '<', $path or die "$path: $!";
    my $src = do { local $/; <$fh> };
    close $fh;

    my $doc = Typist::LSP::Document->new(uri => "file://$path", content => $src);
    $doc->analyze(workspace_registry => $reg);

    # Hover on order_total (line 11, 0-indexed = 10)
    my $sym1 = $doc->symbol_at(10, 5);
    ok $sym1, 'order_total symbol found';
    if ($sym1) {
        my $hover = Typist::LSP::Hover->hover($sym1);
        my $val = $hover->{contents}{value};
        like $val, qr/order_total/,  'contains function name';
        like $val, qr/OrderItem/,    'contains cross-file type OrderItem';
        like $val, qr/Price/,        'contains cross-file type Price';
    }

    # Hover on create_order (line 20, 0-indexed = 19)
    my $sym2 = $doc->symbol_at(19, 5);
    ok $sym2, 'create_order symbol found';
    if ($sym2) {
        my $hover = Typist::LSP::Hover->hover($sym2);
        my $val = $hover->{contents}{value};
        like $val, qr/create_order/, 'contains function name';
        like $val, qr/OrderId/,      'contains cross-file newtype OrderId';
        like $val, qr/Order/,        'contains cross-file type Order';
        like $val, qr/Logger/,       'contains cross-file effect Logger';
    }
};

# ── Completion in Cross-file Context ─────────────

subtest 'completion provides workspace types and effects' => sub {
    my @type_names  = $ws->all_typedef_names;
    my @effect_names = $ws->all_effect_names;

    # Type completions include cross-file definitions
    ok((grep { $_ eq 'Product'   } @type_names), 'Product in type completions');
    ok((grep { $_ eq 'ProductId' } @type_names), 'ProductId in type completions');
    ok((grep { $_ eq 'OrderId'   } @type_names), 'OrderId in type completions');

    # Effect completions include cross-file definitions
    ok((grep { $_ eq 'Logger' } @effect_names), 'Logger in effect completions');

    # Completion module returns proper items
    my $type_items = Typist::LSP::Completion->complete('type_expr', \@type_names, \@effect_names);
    ok scalar @$type_items > 0, 'type completion returns items';
    ok((grep { $_->{label} eq 'Product' } @$type_items), 'Product in completion items');

    my $eff_items = Typist::LSP::Completion->complete('effect', \@type_names, \@effect_names);
    ok scalar @$eff_items > 0, 'effect completion returns items';
    ok((grep { $_->{label} eq 'Logger' } @$eff_items), 'Logger in effect completion items');
};

done_testing;
