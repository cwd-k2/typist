package Typist::External;
use v5.40;

our $VERSION = '0.01';

# External function declarations (declare).
# Extracted from Typist.pm for module decomposition.

sub _declare ($name, $type_expr_str) {
    my $ann = Typist::Parser->parse_annotation($type_expr_str);
    my $type = $ann->{type};

    # Determine package and function name
    my ($pkg, $fn_name);
    if ($name =~ /::/) {
        ($pkg, $fn_name) = $name =~ /\A(.+)::(\w+)\z/;
        die("Typist: declare — invalid qualified name '$name'\n")
            unless $pkg && $fn_name;
    } else {
        ($pkg, $fn_name) = ('CORE', $name);
    }

    # Extract signature components
    my (@param_types, $return_type, $effects);
    if ($type->is_func) {
        @param_types = $type->params;
        $return_type = $type->returns;
        $effects     = $type->effects
            ? Typist::Type::Eff->new($type->effects) : undef;
    } else {
        $return_type = $type;
    }

    # Parse generic declarations
    my @generics;
    if ($ann->{generics_raw} && @{$ann->{generics_raw}}) {
        my $spec = join(', ', $ann->{generics_raw}->@*);
        @generics = Typist::Attribute->parse_generic_decl($spec);
    }

    Typist::Registry->register_function($pkg, $fn_name, +{
        params   => \@param_types,
        returns  => $return_type,
        generics => \@generics,
        effects  => $effects,
    });
}

1;
