package Typist::Newtype::Base;
use v5.40;

sub base ($self) { $$self }

1;

__END__

=head1 NAME

Typist::Newtype::Base - Base class for newtype value wrappers

=head1 DESCRIPTION

Typist::Newtype::Base provides the C<base> accessor shared by all
newtype values. Newtype classes inherit from this module so that
C<< $val->base >> extracts the wrapped inner value.

=head2 base

    my $inner = $val->base;

Returns the inner value wrapped by the newtype. Newtypes are blessed
scalar references, so this dereferences the underlying scalar.

=head1 SEE ALSO

L<Typist>, L<Typist::Registry>

=cut
