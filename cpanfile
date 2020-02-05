requires 'Mojolicious';
requires 'JSON::Feed', '1.000';
requires 'Path::Tiny';
requires 'Data::UUID';
requires 'Digest::SHA1';
requires 'XML::FeedPP';
requires 'NewsExtractor';

on test => sub {
    requires 'Test2::V0';
    requires 'Test2::Harness';
};
