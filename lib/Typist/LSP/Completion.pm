package Typist::LSP::Completion;
use v5.40;

# ── Primitive and Parametric Types ───────────────

my @PRIMITIVES   = qw(Any Void Undef Bool Int Num Str);
my @PARAMETRICS  = qw(ArrayRef HashRef Tuple Ref Maybe CodeRef);
my @TYPE_VARS    = qw(T U V K);

# ── Public API ───────────────────────────────────

# Generate completion items based on context.
#   context:  'type_expr' | 'generic'
#   typedefs: arrayref of typedef names from workspace
sub complete ($class, $context, $typedefs) {
    $typedefs //= [];

    if ($context eq 'generic') {
        return [map { _item($_, 'TypeParameter', "$_ type variable") } @TYPE_VARS];
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
        TypeParameter => 25,
    );
    $kinds{$kind} // 1;
}

1;
