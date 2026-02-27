package Shop::Types;
use v5.40;
use lib 'lib';
use Typist;

use Exporter 'import';
our @EXPORT = qw(ProductId OrderId unwrap);

# ── Type Aliases ───────────────────────────────

BEGIN {
    typedef Price    => 'Int';
    typedef Quantity => 'Int';

    typedef Product => '{ id => ProductId, name => Str, price => Price, stock => Quantity }';

    typedef OrderItem => '{ product_id => ProductId, quantity => Quantity }';
    typedef Order     => '{ id => OrderId, items => ArrayRef[OrderItem], total => Price }';
}

# ── Newtypes ───────────────────────────────────

BEGIN {
    newtype ProductId => 'Str';
    newtype OrderId   => 'Int';
}

# ── Effects ────────────────────────────────────

BEGIN {
    effect Logger => +{
        log => 'CodeRef[Str -> Void]',
    };
}

# ── Type Classes ───────────────────────────────

BEGIN {
    typeclass 'Printable', 'T',
        display => 'CodeRef[T -> Str]';

    instance 'Printable', 'Int',
        display => sub ($v) { "Int<$v>" };

    instance 'Printable', 'Str',
        display => sub ($v) { qq[Str<$v>] };
}

1;
