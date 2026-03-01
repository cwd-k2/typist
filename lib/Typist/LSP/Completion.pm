package Typist::LSP::Completion;
use v5.40;

our $VERSION = '0.01';

# ── Primitive and Parametric Types ───────────────

my @PRIMITIVES   = qw(Any Void Never Undef Bool Int Num Str);
my @PARAMETRICS  = qw(ArrayRef HashRef Tuple Ref Maybe CodeRef);
my @TYPE_VARS    = qw(T U V K);

# ── Public API ───────────────────────────────────

# Generate completion items based on context.
#   context:     'type_expr' | 'generic' | 'effect' | 'constraint'
#   typedefs:    arrayref of typedef names from workspace
#   effects:     arrayref of effect names from workspace
#   typeclasses: arrayref of typeclass names from workspace
sub complete ($class, $context, $typedefs, $effects, $typeclasses = undef) {
    $typedefs    //= [];
    $effects     //= [];
    $typeclasses //= [];

    if ($context eq 'generic') {
        return [map { _item($_, 'TypeParameter', "$_ type variable") } @TYPE_VARS];
    }

    if ($context eq 'effect') {
        return [map { _item($_, 'Event', "effect $_") } @$effects];
    }

    if ($context eq 'constraint') {
        return [map { _item($_, 'Interface', "typeclass $_") } @$typeclasses];
    }

    if ($context eq 'type_expr') {
        my @items;

        # Primitives
        push @items, map { _item($_, 'Class', "Primitive type $_") } @PRIMITIVES;

        # Parametric types with snippet insertion
        push @items, map { _item_snippet($_, 'Class') } @PARAMETRICS;

        # Workspace typedefs
        push @items, map { _item($_, 'Class', "typedef $_") } @$typedefs;

        return \@items;
    }

    [];
}

# ── Code Completion API ────────────────────────

# Generate code completion items based on code-level context.
#   context:  { kind => ..., ... } from Document->code_completion_at
#   doc:      Typist::LSP::Document (analyzed)
#   registry: Typist::Registry
sub complete_code ($class, $context, $doc, $registry) {
    my $kind = $context->{kind};

    if ($kind eq 'struct_field') {
        return $class->_complete_struct_fields($context, $doc, $registry);
    }
    if ($kind eq 'method') {
        return $class->_complete_methods($context, $doc, $registry);
    }
    if ($kind eq 'effect_op') {
        return $class->_complete_effect_ops($context, $registry);
    }

    [];
}

sub _complete_struct_fields ($class, $context, $doc, $registry) {
    my $var_name = $context->{var};
    my $prefix   = $context->{prefix} // '';

    my $type_str = $doc->_resolve_var_type($var_name) // return [];

    # Parse the type string into a type object
    require Typist::Parser;
    my $type = eval { Typist::Parser->parse($type_str) };
    return [] if $@ || !$type;

    # If it's an alias, try to resolve it
    if ($type->is_alias && $registry) {
        $type = eval { $registry->lookup_type($type->alias_name) } // $type;
    }

    return [] unless $type->is_struct;

    my @items;
    my $req = $type->required_ref;
    my $opt = $type->optional_ref;

    for my $field (sort keys %$req) {
        next if $prefix ne '' && index($field, $prefix) != 0;
        push @items, +{
            label  => $field,
            kind   => 5,  # Field
            detail => $req->{$field}->to_string,
        };
    }
    for my $field (sort keys %$opt) {
        next if $prefix ne '' && index($field, $prefix) != 0;
        push @items, +{
            label  => $field,
            kind   => 5,  # Field
            detail => $opt->{$field}->to_string . ' (optional)',
        };
    }

    \@items;
}

sub _complete_methods ($class, $context, $doc, $registry) {
    my $prefix = $context->{prefix} // '';

    return [] unless $registry;

    # Find the current package from the document analysis
    my $result = $doc->{result} // return [];
    my $pkg    = $result->{extracted}{package} // 'main';

    my @items;

    # Collect methods registered for this package
    my %methods = $registry->all_methods;
    my $pkg_prefix = "${pkg}::";
    for my $fqn (sort keys %methods) {
        next unless index($fqn, $pkg_prefix) == 0;
        my $name = substr($fqn, length($pkg_prefix));
        next if $prefix ne '' && index($name, $prefix) != 0;
        my $sig = $methods{$fqn};
        my $detail = _sig_detail($sig);
        push @items, +{
            label  => $name,
            kind   => 2,  # Method
            detail => $detail,
        };
    }

    # Also look at functions marked as methods in the extracted data
    my %functions = $registry->all_functions;
    for my $fqn (sort keys %functions) {
        next unless index($fqn, $pkg_prefix) == 0;
        my $name = substr($fqn, length($pkg_prefix));
        next if $prefix ne '' && index($name, $prefix) != 0;
        # Skip if already added from methods
        next if exists $methods{"${pkg}::${name}"};
        my $sig = $functions{$fqn};
        # Only include functions that look like methods (from extracted data)
        my $extracted_fn = ($result->{extracted}{functions} // +{})->{$name};
        next unless $extracted_fn && $extracted_fn->{is_method};
        my $detail = _sig_detail($sig);
        push @items, +{
            label  => $name,
            kind   => 2,  # Method
            detail => $detail,
        };
    }

    \@items;
}

sub _complete_effect_ops ($class, $context, $registry) {
    my $effect_name = $context->{effect};
    my $prefix      = $context->{prefix} // '';

    return [] unless $registry;

    my $eff = $registry->lookup_effect($effect_name) // return [];

    my @items;
    for my $op ($eff->op_names) {
        next if $prefix ne '' && index($op, $prefix) != 0;
        my $type_str = $eff->get_op($op) // '';
        push @items, +{
            label  => $op,
            kind   => 2,  # Method
            detail => "$effect_name\::$op $type_str",
        };
    }

    \@items;
}

# Build a human-readable detail string from a function signature hash.
sub _sig_detail ($sig) {
    my @params;
    if ($sig->{params}) {
        @params = map { ref $_ ? $_->to_string : $_ } @{$sig->{params}};
    } elsif ($sig->{params_expr}) {
        @params = @{$sig->{params_expr}};
    }
    my $detail = '(' . join(', ', @params) . ')';
    if ($sig->{returns}) {
        $detail .= ' -> ' . (ref $sig->{returns} ? $sig->{returns}->to_string : $sig->{returns});
    } elsif ($sig->{returns_expr}) {
        $detail .= " -> $sig->{returns_expr}";
    }
    $detail;
}

# ── Item Builders ────────────────────────────────

sub _item ($label, $kind, $detail) {
    +{
        label  => $label,
        kind   => _kind_number($kind),
        detail => $detail,
    };
}

sub _item_snippet ($name, $kind) {
    +{
        label            => $name,
        kind             => _kind_number($kind),
        detail           => "Parametric type $name\[...]",
        insertText       => "${name}[\${1}]",
        insertTextFormat => 2,  # Snippet
    };
}

# LSP CompletionItemKind numbers
sub _kind_number ($kind) {
    my %kinds = (
        Class         => 7,
        Interface     => 8,
        Event         => 23,
        TypeParameter => 25,
    );
    $kinds{$kind} // 1;
}

1;
