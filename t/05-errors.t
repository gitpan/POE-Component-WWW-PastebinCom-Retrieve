#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 3;

my $Test_paste_number = 'ffdsfdsfsdfsdfsdfsdfsdfsfsdfsdfsdfsdfsdfs3fdae56d';

use POE qw(Component::WWW::PastebinCom::Retrieve);
my $poco = POE::Component::WWW::PastebinCom::Retrieve->spawn(debug=>1,
timeout => 10);

POE::Session->create(
    package_states => [ main => [qw(_start ret)]],
);

$poe_kernel->run;

sub _start {
    $poco->retrieve({ id => $Test_paste_number, event => 'ret' });
}

sub ret {
    my $in = $_[ARG0];
    is(
        ref $in,
        'HASH',
        '$_[ARG0]',
    );
    ok( length $in->{error}, 'error must have content' );
    ok( not(exists $in->{content}), 'must not have {content}');

    $poco->shutdown;
}