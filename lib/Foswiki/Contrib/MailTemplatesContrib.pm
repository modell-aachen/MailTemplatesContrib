# See bottom of file for default license and copyright information

=begin TML

---+ package Foswiki::Contrib::MailTemplatesContrib

This contrib is meant to handle common tasks when sending mails via plugins.

=cut

package Foswiki::Contrib::MailTemplatesContrib;

use strict;
use warnings;

use JSON;

use MIME::Base64;

use Error ':try';

our $VERSION = '1.0';

our $RELEASE = '1.0';

our $SHORTDESCRIPTION = 'Helper for plugins for sending mails.';

=begin TML

---++ Helper methods

=cut

=begin TML

---+++ listToUsers($list) -> \@usersArray

Convert a string of comma-separated users and groups to an array of users.
   * =$list= - comma-separated list of users and groups
   * =$dummyUsers= - hashref for dummy users, when a mail is not associated with an account; if undef those mails will be discarded

Return: =\@usersArray= array of all users in that list

Each group will be expanded (recursiveley), however each user will be listed
only once, regardless in how often he may appear in the list.

=cut

sub listToUsers {
    my ($list, $dummyUsers) = @_;

    return unless $list;

    my $users = ();
    $list = Foswiki::Func::expandCommonVariables( $list );
    return unless $list;
    foreach my $entry ( split(',', $list ) ) {
        $entry =~ s#^\s*##;
        $entry =~ s#\s*$##;
        next unless $entry;
        if ( Foswiki::Func::isGroup($entry)) {
            my $it = Foswiki::Func::eachGroupMember($entry);
            while ($it->hasNext()) {
                my $user = $it->next();
                $users->{$user} = 1;
            }
        }
        else {
            if ($entry =~ m#$Foswiki::regex{emailAddrRegex}#) {
                my @mailOwners = Foswiki::Func::emailToWikiNames($entry);
                if(scalar @mailOwners) {
                    foreach my $owner ( @mailOwners ) {
                        $users->{$owner} = 1;
                    }
                } elsif ($dummyUsers) {
                    # we are not terribly efficient here, lets hope we do not
                    # want to spam half a continent
                    (my $dummy) = grep { $entry eq $dummyUsers->{$_} } values %$dummyUsers;
                    unless ($dummy) {
                        $dummy = 'UnknownUser' . scalar keys %$dummyUsers unless $dummy;
                        $dummyUsers->{$dummy} = $entry;
                    }
                    $users->{$dummy} = 1;
                }
            } else {
                my $user = Foswiki::Func::getWikiName($entry);
                if($user) {
                    $users->{$user} = 1;
                }
            }
        }
    }
    my @usersArray = keys %$users;
    return unless scalar @usersArray;
    return \@usersArray;
}

=begin TML

---+++ usersToMails($users, $includeCurrent, $skipMails, $skipUsers, $includeUsers) -> \%emails

Transforms a list of users into a hashmap of emails with the associated users.
   * =$users= - arrayref of users
   * =$includeCurrent= - set to true if you want to include the current user
        (you usually do not want to send an email to yourself)
   * =$skipMails= - do not include these email addresses
   * =$skipUsers= - do not include these users
   * =$includeMails= - only include these email addresses
   * =$includeUsers= - only include these users

Return: =\%emails= addresses with their owners

=cut

sub usersToMails {
    my ($users, $includeCurrent, $skipMails, $skipUsers, $includeMails, $includeUsers, $dummyUsers) = @_;

    return unless $users;

    # normalize, we do allow WikiNames here
    # We can not use map, because we need to return the hashes
    foreach my $users ( ($skipUsers, $includeUsers ) ) {
        next unless $users; # includeUsers is usually undef
        foreach my $user ( keys %$users ) {
            my $cUser = Foswiki::Func::getCanonicalUserID($user);
            if($cUser ne $user) {
                delete $users->{$user};
                $users->{$cUser} = 1;
            }
        }
    }

    my $emails = ();
    my $currentUser = Foswiki::Func::getCanonicalUserID();
    foreach my $who (@$users) {
        my @list;
        if ($dummyUsers && $dummyUsers->{$who}) {
            @list = ($dummyUsers->{$who});
        } else {
            $who = Foswiki::Func::getCanonicalUserID( $who ); # normalize for comparison
            next unless $who;
            next if $who eq $currentUser && not $includeCurrent;
            next if defined $skipUsers->{$who};
            next if defined $includeUsers && not defined $includeUsers->{$who};
            @list = Foswiki::Func::wikinameToEmails(Foswiki::Func::getWikiName($who));
            $skipUsers->{$who} = 1 if scalar @list;
        }
        foreach my $mail ( @list ) {
            next if $skipMails->{$mail};
            next if $includeMails && not $includeMails->{$mail};
            $emails->{$mail} = $who;
            $skipMails->{$mail} = 1;
        }
    }
    return $emails if keys %$emails;
}

=begin TML

---++ Plugin workhorses

These are the methods meant to be called when you want to send an email.

=cut

=begin TML

---+++ sendMail($template, $options)
   * =$template= - name of the template for the mail
   * =$options= - ref to hash of options
     | =IncludeCurrentUser= | Do you want to send yourself an email? |
     | =SingleMail= | if true: join all receipients to a single =To= %BR% otherwise: send a separate mail to each receipient |
     | =beforeSend= | ref to callback function that will be called just before the email will be send out |
     | =beforeSendArgs= | arrayref of arguments to the callback%BR%The text of the mail will be unshiftet to this array |
     | =SkipUsers= | do not send mails to users whose WikiName is in this hashref; any user receiving a mail will be added automatically |
     | =SkipMailUsers= | do not send mails to addresses in this hashref; any address receiving a mail will be added automatically |
     | =IncludeMailUsers= | only send mails to users whose emails are in this hashref |
     | =IncludeUsers= | only send mails to users whose WikiNames are in this hashref |
     | =id= | entries in logfiles will show this id |
     | =GenerateOnly= | only generate mails, do not actually send them |
     | =GenerateInAdvance= | do not delay generating mails to the grinder (use this if you have stuff set in the session or need any of the results like =SkipMailUsers=) |
     | =AllowMailsWithoutUser= | allow mail addresses that have no user associated with them (eg. roles like sales@...). |
   * =$setPreferences= - hash with settings to set with =setPreferencesValue= when rendering the template.
      * Special case =LANGUAGE=: The email will be generated in this language (defaults to browser language or en).
   * =$useDaemon= - use the daemon (if possible)

=cut

sub sendMail {
    my ($template, $options, $setPreferences, $useDaemon) = @_;

    $options = {} unless $options;
    $setPreferences = {} unless $setPreferences;

    my $session = $Foswiki::Plugins::SESSION;

    $setPreferences->{LANGUAGE} = _determineMailLanguage($session, $setPreferences);

    unless($useDaemon && $Foswiki::cfg{Plugins}{TaskDaemonPlugin}{Enabled} && $Foswiki::cfg{Extension}{MailTemplatesContrib}{UseGrinder}) {
        if($options->{webtopic}) {
            my ($web, $topic) = Foswiki::Func::normalizeWebTopicName(undef, $options->{webtopic});
            Foswiki::Func::pushTopicContext($web, $topic);
        }
        try {
            _generateMails($template, $options, $setPreferences);
        } finally {
            if($options->{webtopic}) {
                Foswiki::Func::popTopicContext();
            }
        };

        unless($options->{GenerateOnly}) {
            _sendGeneratedMails($options);
        }
        return;
    }

    my $type;
    if($options->{GenerateInAdvance}) {
        _generateMails(@_);
        return unless scalar @{$options->{GeneratedMails}};
        $type = 'sendGeneratedMails';
    } else {
        $type = 'sendMail';
    }

    my $data = {
        template => $template,
        options => $options,
        setPreferences => $setPreferences,
        user => $session->{user},
        webtopic => $options->{webtopic} ? $options->{webtopic} : $session->{webName} . "." . $session->{topicName},
    };
    my $json = encode_json($data);

    Foswiki::Plugins::TaskDaemonPlugin::send($json, $type, 'MailTemplatesContrib', 0);
}

sub _determineMailLanguage {
    my ($session, $setPreferences) = @_;

    return $setPreferences->{LANGUAGE} if $setPreferences->{LANGUAGE};

    if($Foswiki::Plugins::SESSION->inContext('command_line')) {
        my $query = Foswiki::Func::getRequestObject();
        return $query->param('LANGUAGE')
            || Foswiki::Plugins::DefaultPreferencesPlugin::getSitePreferencesValue('BACKEND_MAIL_LANGUAGE')
            || Foswiki::Plugins::DefaultPreferencesPlugin::getSitePreferencesValue('MAIL_LANGUAGE')
            || Foswiki::Func::getPreferencesValue('LANGUAGE');
    } else {
        return Foswiki::Plugins::DefaultPreferencesPlugin::getSitePreferencesValue('MAIL_LANGUAGE') || $session->i18n->language();
    }
}

sub _sendGeneratedMails {
    my ($options) = @_;

    foreach my $text ( @{$options->{GeneratedMails}} ) {
        my $errors = Foswiki::Func::sendEmail( $text, 5 );
        if ($errors) {
            Foswiki::Func::writeWarning(
                'Failed to send mail'.(($options->{id})?" ($options->{id})":'').':'. $errors
            );
        }
    }
}

sub _reseti18n {
    my ( $language ) = @_;

    my $session = $Foswiki::Plugins::SESSION;
    my $currentLanguage = $session->i18n->language();
    unless ($currentLanguage && $currentLanguage eq $language) {
        # Unfortunately we have to set internal preferences here (Foswiki::Func::setPreferencesValue is not sufficient)
        # The LANGUAGE internal preferences may be set when the language selector is used.
        # So we have to overwrite it for our mails.
        $Foswiki::Plugins::SESSION->{prefs}->setInternalPreferences(LANGUAGE => $language);
        $Foswiki::Plugins::SESSION->reset_i18n();
    }
}

sub _generateMails {
    my ($template, $options, $setPreferences) = @_;

    my $oldPreferences = {};

    my $includeCurrent = $options->{IncludeCurrentUser};

    if($setPreferences) {
        foreach my $pref ( keys %$setPreferences ) {
            $oldPreferences->{$pref} = Foswiki::Func::getPreferencesValue($pref);
            Foswiki::Func::setPreferencesValue($pref, $setPreferences->{$pref});
        }

        my $language = $setPreferences->{LANGUAGE} || 'en';
        _reseti18n($language);
    }

    Foswiki::Func::loadTemplate($template) if $template;

    my $receipients = ();
    my $skipMails = $options->{SkipMailUsers} || {};
    my $skipUsers = $options->{SkipUsers} || {};
    my $includeUsers = $options->{IncludeUsers};
    my $includeMails = $options->{IncludeMailUsers};
    my $dummyUsers = {} if $options->{AllowMailsWithoutUser};

    # Do the general primer
    Foswiki::Func::expandCommonVariables(Foswiki::Func::expandTemplate( 'ModacMailPrimer' ));

    # get people
    $receipients->{WikiTo} = listToUsers( Foswiki::Func::expandTemplate( 'ModacMailTo' ), $dummyUsers );
    $receipients->{WikiCc} = listToUsers( Foswiki::Func::expandTemplate( 'ModacMailCc' ), $dummyUsers );
    $receipients->{WikiBcc} = listToUsers( Foswiki::Func::expandTemplate( 'ModacMailBcc' ), $dummyUsers );

    # get mails
    $receipients->{To} = usersToMails( $receipients->{WikiTo}, $includeCurrent, $skipMails, $skipUsers, $includeMails, $includeUsers, $dummyUsers );
    $receipients->{Cc} = usersToMails( $receipients->{WikiCc}, $includeCurrent, $skipMails, $skipUsers, $includeMails, $includeUsers, $dummyUsers );
    $receipients->{Bcc} = usersToMails( $receipients->{WikiBcc}, $includeCurrent, $skipMails, $skipUsers, $includeMails, $includeUsers, $dummyUsers );

    if (! defined $receipients->{To} || ref($receipients->{To}) ne 'HASH' || ! scalar keys %{$receipients->{To}}) {
        $options->{GeneratedMails} = [];
        return 0;
    }

    # Join to single 'To' field, if requested (otherwise send separate mail to each 'To' mail)
    if( $options->{SingleMail} ) {
        my $mail = '';
        my $wiki = '';
        foreach my $to ( keys %{$receipients->{To}} ) {
            $mail .= ',' if $mail;
            $mail .= $to;
            $wiki .= ', ' if $wiki;
            $wiki .= $receipients->{To}->$to;
        }
        $receipients->{To} = { $mail => $wiki };
    }


    # generate actual mails
    my $count = 1;
    $options->{GeneratedMails} = [] unless exists $options->{GeneratedMails};
    foreach my $to ( keys %{$receipients->{To}} ) {
        Foswiki::Func::setPreferencesValue( 'to_expanded', 'To: '.$to );
        Foswiki::Func::setPreferencesValue( 'to_WikiName', $receipients->{To}->{$to} );
        Foswiki::Func::setPreferencesValue( 'ModacMailCount', $count++ );

        # Do the "each" primer
        Foswiki::Func::expandCommonVariables(Foswiki::Func::expandTemplate( 'ModacMailEachPrimer' ));

        my $text = Foswiki::Func::expandTemplate( "ModacMail" );
        $text = Foswiki::Func::expandCommonVariables( $text );
        $text =~ s#<nop>##g;
        if($options->{beforeSend}) {
            my @args = ((defined $options->{beforeSendArgs})?$options->{beforeSendArgs}:[]);
            unshift (@args, \$text);
            $options->{beforeSend}->(@args);
        }
        unless ($text) {
            Foswiki::Func::writeWarning( "Could not initialize mail".(($options->{id})?" ($options->{id})":'') );
            return;
        }
        my ($header, $body) = split(m#^$#m, $text, 2);
        if($header && $body) {
            $header =~ s#^(\s*Subject\s*:\s*)(.*)#_encodeSubject($1,$2)#gmei;
            $text = $header.$body;
        }
        push(@{$options->{GeneratedMails}}, $text);
    }

    foreach my $pref ( keys %$oldPreferences ) {
        Foswiki::Func::setPreferencesValue($pref, $oldPreferences->{$pref});
    }
    _reseti18n($oldPreferences->{LANGUAGE}) if $oldPreferences->{LANGUAGE};
}

=begin TML

---++ Command Line Interface

These methods are called from cli when you want to send an email.

=cut

=begin TML

---+++ _sendCli

   * special parameters:
     | =options_...= | Set an option, eg. =options_SingleMail=1= |
     | =includefile_...= | include contents of a file, eg. =includefile_LOG=/home/test/mylog.log= will be made available as =%LOG%= |

=cut

sub _sendCli {
    my $query = Foswiki::Func::getRequestObject();
    my $template = $query->param('template');

    unless ($template) {
        print STDERR "Please specify template.\n";
        return;
    }

    my $options = { IncludeCurrentUser => 1, SingleMail => 0 };

    # provide cli parameters as preferences/options
    foreach my $param ($query->param) {
        Foswiki::Func::setPreferencesValue($param, scalar $query->param($param));

        # put anything with options prefix into the options hash
        if( $param =~ m/options_(.*Users)$/) {
            # users are a special case; we need to turn them into a hash
            my $paramUsers = $1;
            my $users = $query->param($param);
            if($users) {
                my %hash = ();
                map{ $hash{$_} = 1 } @{listToUsers($users)};
                $options->{$paramUsers} = \%hash;
            }
        } elsif ($param =~ m/options_(.*)/) {
            # anything with options prefix needs to go into the options hash
            my $option = $1;
            $options->{$option} = $query->param($param);
        } elsif ($param =~ m/includefile_(.*)/) {
            # read files and store it as preference
            my $prefName = $1;
            my $fileName = $query->param($param);
            my $val = Foswiki::readFile($fileName);
            Foswiki::Func::setPreferencesValue($prefName, $val);
        }
    }

    # send mail
    my $web = $query->param('web');
    my $topic = $query->param('topic') || $Foswiki::cfg{HomeTopicName};
    ($web, $topic) = Foswiki::Func::normalizeWebTopicName($web, $topic);
    Foswiki::Func::pushTopicContext($web, $topic);
    Foswiki::Contrib::MailTemplatesContrib::sendMail($template, $options);
    Foswiki::Func::popTopicContext();

    if($options->{GenerateOnly} && $options->{GeneratedMails}) {
        print join("\n---NEW MAIL---\n", @{$options->{GeneratedMails}});
    }
}

# Encode a subject line according to rfc2047
# TODO: process multiline subjects
sub _encodeSubject {
    my ( $header, $subject ) = @_;

    # Do not encode all-ascii subject
    return $header.$subject if $subject =~ m/^\p{ASCII}*$/;

    # Header and footer for encoded words
    my $pre = '=?utf-8?Q?';
    my $tail = '?=';

    # Encode characters.
    # Encoded stuff is placed in @escapes and a placeholder inserted;
    # this is to prevent splitting multi-byte chars.
    # A placeholder looks like this: \x01...\x01\x02
    my $encoded = $subject;
    my @escapes = ();
    my $escapeChar = sub {
        my $x = $1;
        if($Foswiki::UNICODE) {
            $x = Foswiki::encode_utf8($x);
        }
        my @chars = map{'='.unpack('H*',$_)} split('', $x);
        my $quoted = join('', @chars);
        push(@escapes, $quoted);
        return "\x01" x (length($quoted) - 1) . "\x02"
    };
    # Encode disallowed chars. Note: Also spaces must be encoded.
    $encoded =~ s#([^\x09\x21-\x3c\x3e\x40-\x7e])#&$escapeChar#ge;

    # Put the complete subject line together
    $encoded = $header.$pre.$encoded.$tail;

    # A line containing an encoded word must not exceed 76 chars.
    if ( length($encoded) > 76 ) {
        # Split into multiple encoded words.
        # Note: white spaces betweed these will be ignored
        my @chunks = ();

        # Ignoring that the first line may actually be longer (no leading
        # space).
        # The last char must not be in the middle of a multi-byte char
        # (escaped as \x01).
        my $maxLength = 74 - length($pre) - length($tail);
        while($encoded =~ m#\G(.{0,$maxLength}[^\x01])#g) {
            push(@chunks, $1);
        }
        $encoded = join("$tail\n $pre", @chunks);
    }

    # re-insert encoded chars
    $encoded =~ s#\x01+\x02#shift @escapes#ge;

    return $encoded;
}


1;

__END__
Foswiki - The Free and Open Source Wiki, http://foswiki.org/

Copyright (C) 2008-2014 Foswiki Contributors. Foswiki Contributors
are listed in the AUTHORS file in the root of this distribution.
NOTE: Please extend that file, not this notice.

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version. For
more details read LICENSE in the root of this distribution.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

As per the GPL, removal of this notice is prohibited.
