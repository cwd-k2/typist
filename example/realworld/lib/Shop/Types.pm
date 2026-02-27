package Shop::Types;
use v5.40;
use lib 'lib';
use Typist;
use Typist::DSL;

use Exporter 'import';
our @EXPORT = qw(ProductId OrderId unwrap);

# ── Newtypes (must come before typedefs that reference them) ──

BEGIN {
    newtype ProductId => Str;
    newtype OrderId   => Int;
}

# ── Type Aliases ───────────────────────────────

BEGIN {
    typedef Price    => Int;
    typedef Quantity => Int;

    typedef Product   => Struct(id => Alias('ProductId'), name => Str, price => Alias('Price'), stock => Alias('Quantity'));

    typedef OrderItem => Struct(product_id => Alias('ProductId'), quantity => Alias('Quantity'));
    typedef Order     => Struct(id => Alias('OrderId'), items => ArrayRef(Alias('OrderItem')), total => Alias('Price'));
}

# ── Effects ────────────────────────────────────

BEGIN {
    effect Logger => +{
        log => Func(Str, returns => Void),
    };
}

# ── Type Classes ───────────────────────────────

BEGIN {
    typeclass Printable => T, +{
        display => Func(T, returns => Str),
    };

    instance Printable => Int, +{
        display => sub ($v) { "Int<$v>" },
    };

    instance Printable => Str, +{
        display => sub ($v) { qq[Str<$v>] },
    };
}

1;
