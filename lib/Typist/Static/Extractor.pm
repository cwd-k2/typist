package Typist::Static::Extractor;
use v5.40;

use PPI;

# ── Public API ───────────────────────────────────

# Extract type annotations from Perl source text.
# Returns a structured hash of aliases, variables, functions, and package name.
sub extract ($class, $source) {
    my $doc = PPI::Document->new(\$source)
        or die "Typist::Static::Extractor: failed to parse source";

    my $result = +{
        aliases   => +{},
        variables => [],
        functions => +{},
        package   => 'main',
    };

    # Detect package declaration
    if (my $pkg = $doc->find_first('PPI::Statement::Package')) {
        $result->{package} = $pkg->namespace;
    }

    $class->_extract_typedefs($doc, $result);
    $class->_extract_variables($doc, $result);
    $class->_extract_functions($doc, $result);

    $result;
}

# ── typedef Extraction ──────────────────────────

sub _extract_typedefs ($class, $doc, $result) {
    my $statements = $doc->find('PPI::Statement') || [];

    for my $stmt (@$statements) {
        my @children = $stmt->schildren;
        next unless @children >= 4;

        # typedef Name => 'Expr'
        next unless $children[0]->isa('PPI::Token::Word')
                 && $children[0]->content eq 'typedef';

        my $name = $children[1]->content;
        # Skip => operator
        next unless $children[2]->isa('PPI::Token::Operator')
                 && $children[2]->content eq '=>';

        my $expr_tok = $children[3];
        my $expr = $expr_tok->isa('PPI::Token::Quote')
            ? $expr_tok->string
            : $expr_tok->content;

        $result->{aliases}{$name} = +{
            expr => $expr,
            line => $stmt->line_number,
            col  => $stmt->column_number,
        };
    }
}

# ── Variable Extraction ─────────────────────────

# PPI does not recognize variable attributes as PPI::Token::Attribute.
# Instead, `my $x :Type(Int)` is parsed as:
#   Symbol($x) Operator(:) Word(Type) List( Expression(Word(Int)) )
# We detect this pattern by scanning PPI::Statement::Variable children.
sub _extract_variables ($class, $doc, $result) {
    my $stmts = $doc->find('PPI::Statement::Variable') || [];

    for my $stmt (@$stmts) {
        my @children = $stmt->schildren;

        # Find the variable symbol
        my $var_name;
        for my $i (0 .. $#children) {
            my $child = $children[$i];

            if ($child->isa('PPI::Token::Symbol')) {
                $var_name = $child->content;
                next;
            }

            # Look for : operator followed by Word('Type') followed by List
            next unless $child->isa('PPI::Token::Operator')
                     && $child->content eq ':'
                     && $var_name;

            my $next = $children[$i + 1] // next;
            next unless $next->isa('PPI::Token::Word')
                     && $next->content eq 'Type';

            my $list = $children[$i + 2] // next;
            next unless $list->isa('PPI::Structure::List');

            # Extract the type expression from the list content
            my $type_expr = $class->_list_content($list);
            next unless $type_expr;

            push $result->{variables}->@*, +{
                name      => $var_name,
                type_expr => $type_expr,
                line      => $next->line_number,
                col       => $next->column_number,
            };
        }
    }
}

# ── Function Extraction ─────────────────────────

sub _extract_functions ($class, $doc, $result) {
    my $subs = $doc->find('PPI::Statement::Sub') || [];

    for my $sub_stmt (@$subs) {
        my $name = $sub_stmt->name // next;

        my $attrs = $sub_stmt->find('PPI::Token::Attribute') || [];
        next unless @$attrs;

        my (@params_expr, $returns_expr, @generics);

        for my $attr (@$attrs) {
            my $content = $attr->content;

            if ($content =~ /\AParams\((.+)\)\z/) {
                @params_expr = split /\s*,\s*/, $1;
            }
            elsif ($content =~ /\AReturns\((.+)\)\z/) {
                $returns_expr = $1;
            }
            elsif ($content =~ /\AGeneric\((.+)\)\z/) {
                @generics = split /\s*,\s*/, $1;
            }
        }

        next unless @params_expr || $returns_expr;

        $result->{functions}{$name} = +{
            params_expr  => \@params_expr,
            returns_expr => $returns_expr,
            generics     => \@generics,
            line         => $sub_stmt->line_number,
            col          => $sub_stmt->column_number,
        };
    }
}

# ── Helpers ──────────────────────────────────────

# Extract the textual content of a PPI::Structure::List, stripping parens.
sub _list_content ($class, $list) {
    my $raw = $list->content;
    $raw =~ s/\A\(\s*//;
    $raw =~ s/\s*\)\z//;
    length($raw) ? $raw : undef;
}

1;
