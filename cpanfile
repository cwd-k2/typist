requires 'perl', 'v5.40';

# Static analysis
requires 'PPI';

# LSP transport (core since 5.14, declared for clarity)
requires 'JSON::PP';

# Timing and tracing (core since 5.7.3, declared for clarity)
requires 'Time::HiRes';

# Editor integration (optional)
recommends 'Perl::Critic';
