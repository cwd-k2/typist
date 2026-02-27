package Shop::Inventory;
use v5.40;
use lib 'lib';
use Typist;
use Typist::DSL;
use Shop::Types;

# ── Internal Storage ───────────────────────────

my %products;

# ── Public API ─────────────────────────────────

sub add_product :Params(Product) :Returns(Bool) ($product) {
    my $id = unwrap($product->{id});
    $products{$id} = $product;
    1;
}

sub find_product :Params(ProductId) :Returns(Product) ($id) {
    my $key = unwrap($id);
    $products{$key} // die "Typist: product not found: $key\n";
}

sub in_stock :Params(ProductId, Quantity) :Returns(Bool) ($id, $qty) {
    my $key = unwrap($id);
    my $product = $products{$key} // return 0;
    $product->{stock} >= $qty ? 1 : 0;
}

sub clear {
    %products = ();
}

1;
