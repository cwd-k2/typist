package Shop::Order;
use v5.40;
use lib 'lib';
use Typist;
use Typist::DSL;
use Shop::Types;
use Shop::Inventory;

# ── Order Processing ───────────────────────────

sub order_total :Params(ArrayRef[OrderItem]) :Returns(Price) ($items) {
    my $total = 0;
    for my $item (@$items) {
        my $product = Shop::Inventory::find_product($item->{product_id});
        $total += $product->{price} * $item->{quantity};
    }
    $total;
}

sub create_order :Params(OrderId, ArrayRef[OrderItem]) :Returns(Order) :Eff(Logger) ($id, $items) {
    my $total = order_total($items);
    +{
        id    => $id,
        items => $items,
        total => $total,
    };
}

1;
