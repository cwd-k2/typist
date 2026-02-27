requires 'perl', 'v5.40';

# Static analysis
requires 'PPI';

# LSP transport (core since 5.14, declared for clarity)
requires 'JSON::PP';

# Editor integration (optional)
recommends 'Perl::Critic';
