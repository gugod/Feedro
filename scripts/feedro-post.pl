#!/usr/bin/env perl
use v5.18;
use strict;
use warnings;
use Mojo::UserAgent;
use Getopt::Long qw< GetOptions >;
use JSON qw< encode_json >;
use Data::Dumper qw< Dumper >;

my %opts;
GetOptions(
    \%opts,
    "title=s",
    "content_text=s",
    "url=s",
    "token=s"
);

my $feed_url = $ARGV[0] or die "A feed URL is required.";
die "`title` is required.\n" unless $opts{title};
die "`token` is required.\n" unless $opts{token};

my %item;

for my $k (qw<title url content_text>) {
    next unless exists $opts{$k};
    $item{$k} = $opts{$k};
    utf8::decode( $item{$k} );
}

$item{id} = $item{url} if $item{url};

$feed_url =~ s{\.json}{/items};

my $ua = Mojo::UserAgent->new;
my $tx = $ua->post(
    $feed_url,
    { Authentication => "Bearer $opts{token}" },
    json => \%item,
);
my $res = $tx->result;
if ($res->is_error) {
    say "Error: " . $res->message;
} elsif ($res->is_success) {
    say 'Success';
} else {
    say "Not sure what happened... Response:";
    say $res->code;
    say $res->body;
}

__END__

feedro-post.pl https://example.com/feed/links.json --token ooxxooxxooxxooxx --url 'https://example.com/item/1' --title 'A new item is here' --content_text 'Some text content here.'
