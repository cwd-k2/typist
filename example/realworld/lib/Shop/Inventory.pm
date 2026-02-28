package Shop::Inventory;
use v5.40;
use lib 'lib';
use Typist;
use Typist::DSL;
use Shop::Types;

# ── Internal Storage ───────────────────────────

my %products;

# ── Public API ─────────────────────────────────

sub add_product :Type((Product) -> Bool) ($product) {
    my $id = unwrap($product->{id});
    $products{$id} = $product;
    1;
}

sub find_product :Type((ProductId) -> Product) ($id) {
    my $key = unwrap($id);
    $products{$key};
}

sub in_stock :Type((ProductId, Quantity) -> Bool) ($id, $qty) {
    my $key = unwrap($id);
    my $product = $products{$key} // return 0;
    $product->{stock} >= $qty ? 1 : 0;
}

sub clear {
    %products = ();
}

1;
