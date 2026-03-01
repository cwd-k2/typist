package Typist::LSP;
use v5.40;

our $VERSION = '0.01';

use Typist::LSP::Server;

sub run ($class) {
    my $server = Typist::LSP::Server->new;
    $server->run;

    # LSP spec: exit 0 if shutdown was received, 1 otherwise
    exit($server->did_shutdown ? 0 : 1);
}

1;
