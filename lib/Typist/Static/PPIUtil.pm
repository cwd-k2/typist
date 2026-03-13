package Typist::Static::PPIUtil;
use v5.40;

our $VERSION = '0.01';

use Exporter 'import';
our @EXPORT_OK = qw(split_comma_groups);

# Split a list of PPI children at comma operators into groups.
# Returns a list of arrayrefs, each containing the PPI elements
# between commas.  Empty groups (adjacent commas) are skipped.
#
#   my @groups = split_comma_groups($expr->schildren);
#
sub split_comma_groups (@children) {
    my @groups;
    my @current;
    for my $child (@children) {
        if ($child->isa('PPI::Token::Operator') && $child->content eq ',') {
            push @groups, [@current] if @current;
            @current = ();
        } else {
            push @current, $child;
        }
    }
    push @groups, [@current] if @current;
    @groups;
}

1;
