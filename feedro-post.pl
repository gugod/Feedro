#!/usr/bin/env perl
use v5.18;
use strict;
use warnings;
use HTTP::Tiny;
use Getopt::Long qw< GetOptions >;
use JSON qw< encode_json >;
use Data::UUID;
use Data::Dumper qw< Dumper >;

my %opts;
GetOptions(
    \%opts,
    "url=s",
    "title=s",
    "content_text=s",
);

my $feed_url = $ARGV[0] or die "A feed URL is required.";
die "`title` is required.\n" unless $opts{title};

my %item;

$item{id} = Data::UUID->new->create_str;

for my $k (qw<title url content_text>) {
    next unless exists $opts{$k};
    $item{$k} = $opts{$k};
    utf8::decode( $item{$k} );
}

$feed_url =~ s{\.json}{/items};

my $response = HTTP::Tiny->new->post(
    $feed_url,
    { content => encode_json(\%item) }
);

if ($response->{success}) {
    say 'Success';
} else {
    say 'Failed.';
    say Dumper($response);
}

__END__

feedro-post.pl https://example.com/feed/links.json --url 'https://example.com/item/1' --title 'A new item is here' --content_text 'Some text content here.'

