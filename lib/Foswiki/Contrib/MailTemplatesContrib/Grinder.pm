use strict;
use warnings;

use JSON;

use Foswiki::Contrib::MailTemplatesContrib;

{
    handle_message => sub {
        my ($host, $type, $hdl, $run_engine, $json) = @_;

        eval {
            my $data = decode_json($json->{data});
            push (@ARGV, "/".$data->{webtopic}); # XXX
            $Foswiki::engine->{user} = $data->{user};
            $run_engine->();
            pop @ARGV;
        };

        return {};
    },
    engine_part => sub {
        my ($session, $type, $data, $caches) = @_;

        $data = decode_json($data);

        if($type eq 'sendMail') {
            Foswiki::Contrib::MailTemplatesContrib::_generateMails($data->{template}, $data->{options}, $data->{setPreferences});
            Foswiki::Contrib::MailTemplatesContrib::_sendGeneratedMails($data->{options});
        } elsif ($type eq 'sendGeneratedMails') {
            Foswiki::Contrib::MailTemplatesContrib::_sendGeneratedMails($data->{options});
        } else {
            Foswiki::Func::writeWarning("Unknown command: $type");
        }
    },
};
