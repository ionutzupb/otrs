# --
# Copyright (C) 2001-2016 OTRS AG, http://otrs.com/
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (AGPL). If you
# did not receive this file, see http://www.gnu.org/licenses/agpl.txt.
# --

package Kernel::System::Email;
## nofilter(TidyAll::Plugin::OTRS::Perl::Require)

use strict;
use warnings;

use Mail::Address;
use MIME::Entity;
use MIME::Parser;
use MIME::Words;

use Kernel::System::VariableCheck qw(:all);

our @ObjectDependencies = (
    'Kernel::Config',
    'Kernel::System::Crypt::PGP',
    'Kernel::System::Crypt::SMIME',
    'Kernel::System::Encode',
    'Kernel::System::HTMLUtils',
    'Kernel::System::Log',
);

=head1 NAME

Kernel::System::Email - to send email

=head1 DESCRIPTION

Global module to send email via sendmail or SMTP.

=head1 PUBLIC INTERFACE

=head2 new()

Don't use the constructor directly, use the ObjectManager instead:

    my $EmailObject = $Kernel::OM->Get('Kernel::System::Email');

=cut

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {%Param};
    bless( $Self, $Type );

    # debug level
    $Self->{Debug} = $Param{Debug} || 0;

    # get configured backend module
    my $GenericModule = $Kernel::OM->Get('Kernel::Config')->Get('SendmailModule')
        || 'Kernel::System::Email::Sendmail';

    # get backend object
    $Self->{Backend} = $Kernel::OM->Get($GenericModule);

    return $Self;
}

=head2 Send()

To send an email without already created header:

    my $Sent = $SendObject->Send(
        From          => 'me@example.com',
        To            => 'friend@example.com',
        Cc            => 'Some Customer B <customer-b@example.com>',   # not required
        ReplyTo       => 'Some Customer B <customer-b@example.com>',   # not required, is possible to use 'Reply-To' instead
        Subject       => 'Some words!',
        Charset       => 'iso-8859-15',
        MimeType      => 'text/plain', # "text/plain" or "text/html"
        Body          => 'Some nice text',
        InReplyTo     => '<somemessageid-2@example.com>',
        References    => '<somemessageid-1@example.com> <somemessageid-2@example.com>',
        Loop          => 1, # not required, removes smtp from
        CustomHeaders => {
            X-OTRS-MyHeader => 'Some Value',
        },
        Attachment => [
            {
                Filename    => "somefile.csv",
                Content     => $ContentCSV,
                ContentType => "text/csv",
            },
            {
                Filename    => "somefile.png",
                Content     => $ContentPNG,
                ContentType => "image/png",
            }
        ],
        EmailSecurity => {
            Backend     => 'PGP',                       # PGP or SMIME
            Method      => 'Detached',                  # Optional Detached or Inline (defaults to Detached)
            SignKey     => '81877F5E',                  # Optional
            EncryptKeys => [ '81877F5E', '3b630c80' ],  # Optional
        }
    );

    my $Sent = $SendObject->Send(                   (Backwards compatibility)
        From                 => 'me@example.com',
        To                   => 'friend@example.com',
        Subject              => 'Some words!',
        Charset              => 'iso-8859-15',
        MimeType             => 'text/plain', # "text/plain" or "text/html"
        Body                 => 'Some nice text',
        InReplyTo            => '<somemessageid-2@example.com>',
        References           => '<somemessageid-1@example.com> <somemessageid-2@example.com>',
        Sign => {
            Type    => 'PGP',
            SubType => 'Inline|Detached',
            Key     => '81877F5E',

            Type => 'SMIME',
            Key  => '3b630c80',
        },
        Crypt => {
            Type    => 'PGP',
            SubType => 'Inline|Detached',
            Key     => '81877F5E',
        },
    );

    if ($Sent) {
        print "Email sent!\n";
    }
    else {
        print "Email not sent!\n";
    }

=cut

sub Send {
    my ( $Self, %Param ) = @_;

    # Check needed stuff.
    for my $Needed (qw(Body Charset)) {
        if ( !$Param{$Needed} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $Needed!",
            );
            return;
        }
    }
    if ( !$Param{To} && !$Param{Cc} && !$Param{Bcc} ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => 'Need To, Cc or Bcc!'
        );
        return;
    }

    # Sign and Encrypt backwards compatibility.
    if ( !IsHashRefWithData( $Param{EmailSecurity} ) ) {
        if ( $Param{Sign} ) {
            $Param{EmailSecurity}->{Backend} ||= $Param{Sign}->{Type}    || '';
            $Param{EmailSecurity}->{Method}  ||= $Param{Sign}->{SubType} || '';
            $Param{EmailSecurity}->{SignKey} ||= $Param{Sign}->{Key}     || '';
        }
        if ( $Param{Crypt} ) {
            $Param{EmailSecurity}->{Backend}     ||= $Param{Crypt}->{Type}    || '';
            $Param{EmailSecurity}->{Method}      ||= $Param{Crypt}->{SubType} || '';
            $Param{EmailSecurity}->{EncryptKeys} ||= [ $Param{Crypt}->{Key} ] || [];
        }
    }

    # Remove EmailSecurity if empty, or invalid
    if ( !IsHashRefWithData( $Param{EmailSecurity} ) ) {
        $Param{EmailSecurity} = undef;
    }

    # Check EmailSecurity options.
    if ( $Param{EmailSecurity} ) {
        if ( ref $Param{EmailSecurity} ne 'HASH' ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "EmailSecurity format is invalid!",
            );

            return;
        }
        elsif ( !$Param{EmailSecurity}->{Backend} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need EmailSecurity Backend!",
            );

            return;
        }
        elsif ( $Param{EmailSecurity}->{Backend} ne 'PGP' && $Param{EmailSecurity}->{Backend} ne 'SMIME' ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "EmailSecurity Backend is invalid!",
            );

            return;
        }

        $Param{EmailSecurity}->{Method} ||= 'Detached';

        if ( $Param{EmailSecurity}->{Method} ne 'Detached' && $Param{EmailSecurity}->{Method} ne 'Inline' ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "EmailSecurity Method is invalid!",
            );

            return;
        }
        elsif ( $Param{EmailSecurity}->{SignKey} && !IsStringWithData( $Param{EmailSecurity}->{SignKey} ) ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "EmailSecurity SignKey is invalid!",
            );

            return;
        }
        elsif ( $Param{EmailSecurity}->{EncryptKeys} && !IsArrayRefWithData( $Param{EmailSecurity}->{EncryptKeys} ) ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "EmailSecurity EncryptKeys is invalid!",
            );

            return;
        }
    }

    # Exchange original reference prevent it to grow up.
    if ( ref $Param{Attachment} && ref $Param{Attachment} eq 'ARRAY' ) {
        my @LocalAttachment = @{ $Param{Attachment} };
        $Param{Attachment} = \@LocalAttachment;
    }

    # Get config object.
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    # Check from
    if ( !$Param{From} ) {
        $Param{From} = $ConfigObject->Get('AdminEmail') || 'otrs@localhost';
    }

    # Replace all <br/> tags with <br /> tags (with a space) to show newlines in Lotus Notes.
    if ( $Param{MimeType} && lc $Param{MimeType} eq 'text/html' ) {
        $Param{Body} =~ s{\Q<br/>\E}{<br />}xmsgi;
    }

    # Map ReplyTo into Reply-To if present.
    if ( $Param{ReplyTo} ) {
        $Param{'Reply-To'} = $Param{ReplyTo};
    }

    # Get encrypt object (if needed).
    my $EncryptObject;
    if ( $Param{EmailSecurity} ) {

        $EncryptObject = $Kernel::OM->Get( 'Kernel::System::Crypt::' . $Param{EmailSecurity}->{Backend} );

        if ( !$EncryptObject ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => 'Not possible to create encrypt object',
            );

            return;
        }
    }

    # Sign body inline.
    if ( $Param{EmailSecurity}->{SignKey} && $Param{EmailSecurity}->{Method} eq 'Inline' ) {

        my $Body = $EncryptObject->Sign(
            Message => $Param{Body},
            Key     => $Param{EmailSecurity}->{SignKey},
            Type    => 'Clearsign',
            Charset => $Param{Charset},
        );

        if ($Body) {
            $Param{Body} = $Body;
        }
    }

    # Encrypt body inline
    if ( $Param{EmailSecurity}->{EncryptKeys} && $Param{EmailSecurity}->{Method} eq 'Inline' ) {

        my $Body = $EncryptObject->Crypt(
            Message => $Param{Body},
            Key     => $Param{EmailSecurity}->{EncryptKeys},
            Type    => $Param{EmailSecurity}->{Method},
        );

        if ($Body) {
            $Param{Body} = $Body;
        }
    }

    # # Create a new Mime Entity (This will all any attachments).
    my $Entity = $Self->_CreateMimeEntity(%Param);

    # Sign email detached
    if ( $Param{EmailSecurity}->{SignKey} && $Param{EmailSecurity}->{Method} eq 'Detached' ) {

        if ( $Param{EmailSecurity}->{Backend} eq 'PGP' ) {

            # Determine used digest for proper micalg declaration.
            my $ClearSign = $EncryptObject->Sign(
                Message => 'dummy',
                Key     => $Param{EmailSecurity}->{SignKey},
                Type    => 'Clearsign',
                Charset => $Param{Charset},
            );
            my $DigestAlgorithm = 'sha1';
            if ($ClearSign) {
                $DigestAlgorithm = lc $1 if $ClearSign =~ m{ \n Hash: [ ] ([^\n]+) \n }xms;
            }

            # Make it multi-part -=> one attachment for sign.
            $Entity->make_multipart(
                "signed; micalg=pgp-$DigestAlgorithm; protocol=\"application/pgp-signature\";",
                Force => 1,
            );

            # Get string to sign.
            my $T = $Entity->parts(0)->as_string();

            # According to RFC3156 all line endings MUST be CR/LF.
            $T =~ s/\x0A/\x0D\x0A/g;
            $T =~ s/\x0D+/\x0D/g;
            my $Signature = $EncryptObject->Sign(
                Message => $T,
                Key     => $Param{EmailSecurity}->{SignKey},
                Type    => 'Detached',
                Charset => $Param{Charset},
            );

            # If sign failed, remove multi part.
            if ( !$Signature ) {
                $Entity->make_singlepart();
            }
            else {

                # Attach signature to email
                $Entity->attach(
                    Filename => 'pgp_sign.asc',
                    Data     => $Signature,
                    Type     => 'application/pgp-signature',
                    Encoding => '7bit',
                );
            }
        }
        elsif ( $Param{EmailSecurity}->{Backend} eq 'SMIME' ) {

            # Make it multi-part.
            my $EntityCopy = $Entity->dup();
            $EntityCopy->make_multipart(
                'mixed;',
                Force => 1,
            );

            # Get header to remember.
            my $Head = $EntityCopy->head();
            $Head->delete('MIME-Version');
            $Head->delete('Content-Type');
            $Head->delete('Content-Disposition');
            $Head->delete('Content-Transfer-Encoding');
            my $Header = $Head->as_string();

            # Get string to sign.
            my $T = $EntityCopy->parts(0)->as_string();

            # According to RFC3156 all line endings MUST be CR/LF.
            $T =~ s/\x0A/\x0D\x0A/g;
            $T =~ s/\x0D+/\x0D/g;

            # Remove empty line after multi-part preamble as it will be removed later by MIME::Parser
            #    otherwise signed content will be different than the actual mail and verify will
            #    fail.
            $T =~ s{(This is a multi-part message in MIME format...\r\n)\r\n}{$1}g;

            my $Signature = $EncryptObject->Sign(
                Message  => $T,
                Filename => $Param{EmailSecurity}->{SignKey},
                Type     => 'Detached',
            );
            if ($Signature) {

                my $Parser = MIME::Parser->new();
                $Parser->output_to_core('ALL');

                $Parser->output_dir( $ConfigObject->Get('TempDir') );
                $Entity = $Parser->parse_data( $Header . $Signature );
            }
        }
    }

    # Encrypt email detached!
    #my $NotCryptedBody = $Entity->body_as_string();
    if ( $Param{EmailSecurity}->{EncryptKeys} && $Param{EmailSecurity}->{Method} eq 'Detached' ) {

        if ( $Param{EmailSecurity}->{Backend} eq 'PGP' ) {

            # Make it multi-part -=> one attachment for encryption
            $Entity->make_multipart(
                "encrypted; protocol=\"application/pgp-encrypted\";",
                Force => 1,
            );

            # Encrypt it.
            my $EncryptedMessage = $EncryptObject->Crypt(
                Message => $Entity->parts(0)->as_string(),
                Key     => $Param{EmailSecurity}->{EncryptKeys},
            );

            # If crypt failed, remove encrypted multi-part.
            if ( !$EncryptedMessage ) {
                $Entity->make_singlepart();
            }
            else {

                # Eliminate all parts.
                $Entity->parts( [] );

                # Add encrypted parts.
                $Entity->attach(
                    Type        => 'application/pgp-encrypted',
                    Disposition => 'attachment',
                    Data        => [ "Version: 1", "" ],
                    Encoding    => '7bit',
                );
                $Entity->attach(
                    Type        => 'application/octet-stream',
                    Disposition => 'inline',
                    Filename    => 'msg.asc',
                    Data        => $EncryptedMessage,
                    Encoding    => '7bit',
                );
            }
        }
        elsif ( $Param{EmailSecurity}->{Backend} eq 'SMIME' ) {

            # Make it multi-part -=> one attachment for encryption
            $Entity->make_multipart(
                'mixed;',
                Force => 1,
            );

            # Get header to remember.
            my $Head = $Entity->head();
            $Head->delete('MIME-Version');
            $Head->delete('Content-Type');
            $Head->delete('Content-Disposition');
            $Head->delete('Content-Transfer-Encoding');
            my $Header = $Head->as_string();

            my $T = $Entity->parts(0)->as_string();

            # According to RFC3156 all line endings MUST be CR/LF.
            $T =~ s/\x0A/\x0D\x0A/g;
            $T =~ s/\x0D+/\x0D/g;

            # Convert Encrypt Keys to a search structure for SMIME
            #   From:
            #       [ '123', '456' ]
            #   To:
            #       (
            #           {
            #               Filename => '123',
            #           },
            #           {
            #               Filename => '456',
            #           },
            #       )
            my @Certificates = map { { Filename => $_ } } @{ $Param{EmailSecurity}->{EncryptKeys} };

            # Encrypt it
            my $EncryptedMessage = $EncryptObject->Crypt(
                Message      => $T,
                Certificates => \@Certificates,
            );

            my $Parser = MIME::Parser->new();

            $Parser->output_dir( $ConfigObject->Get('TempDir') );
            $Entity = $Parser->parse_data( $Header . $EncryptedMessage );
        }
    }

    # Get header from Entity.
    my $Head = $Entity->head();
    $Param{Header} = $Head->as_string();

    # Remove not needed folding of email heads, we do have many problems with email clients.
    my @Headers = split( /\n/, $Param{Header} );

    # reset orig header
    $Param{Header} = '';
    for my $Line (@Headers) {
        $Line =~ s/^    (.*)$/ $1/;

        # Perform own wrapping of long lines due to MIME::Tools problems (see bug#9345).
        #  MIME::Tools fails to wrap long lines where the Message-IDs are too long or
        #  directly concatenated without spaces in between.
        if ( $Line =~ m{^(References|In-Reply-To):}smx ) {
            $Line =~ s{(.{64,}?)>\s*<}{$1>\n <}sxmg;
        }
        $Param{Header} .= $Line . "\n";
    }

    # Get body from Entity.
    $Param{Body} = $Entity->body_as_string();

    # get recipients
    my @ToArray;
    my $To = '';

    RECIPIENT:
    for my $Recipient (qw(To Cc Bcc)) {
        next RECIPIENT if !$Param{$Recipient};
        for my $Email ( Mail::Address->parse( $Param{$Recipient} ) ) {
            push( @ToArray, $Email->address() );
            if ($To) {
                $To .= ', ';
            }
            $To .= $Email->address();
        }
    }

    # add Bcc recipients
    my $SendmailBcc = $ConfigObject->Get('SendmailBcc');
    if ($SendmailBcc) {
        push @ToArray, $SendmailBcc;
        $To .= ', ' . $SendmailBcc;
    }

    # set envelope sender for replies
    my $RealFrom = $ConfigObject->Get('SendmailEnvelopeFrom') || '';
    if ( !$RealFrom ) {
        my @Sender = Mail::Address->parse( $Param{From} );
        $RealFrom = $Sender[0]->address();
    }

    # set envelope sender for auto-responses and notifications
    if ( $Param{Loop} ) {
        $RealFrom = $ConfigObject->Get('SendmailNotificationEnvelopeFrom') || '';
    }

    # debug
    if ( $Self->{Debug} > 1 ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'notice',
            Message  => "Sent email to '$To' from '$RealFrom'. Subject => '$Param{Subject}';",
        );
    }

    # send email to backend
    my $Sent = $Self->{Backend}->Send(
        From    => $RealFrom,
        ToArray => \@ToArray,
        Header  => \$Param{Header},
        Body    => \$Param{Body},
    );

    if ( !$Sent ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Message  => "Error sending message",
            Priority => 'info',
        );
        return;
    }

    return ( \$Param{Header}, \$Param{Body} );
}

=head2 Check()

Check mail configuration

    my %Check = $SendObject->Check();

=cut

sub Check {
    my ( $Self, %Param ) = @_;

    my %Check = $Self->{Backend}->Check();

    if ( $Check{Successful} ) {
        return ( Successful => 1 )
    }
    else {
        return (
            Successful => 0,
            Message    => $Check{Message}
        );
    }
}

=head2 Bounce()

Bounce an email

    $SendObject->Bounce(
        From  => 'me@example.com',
        To    => 'friend@example.com',
        Email => $Email,
    );

=cut

sub Bounce {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for (qw(From To Email)) {
        if ( !$Param{$_} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $_!"
            );
            return;
        }
    }

    # check and create message id
    my $MessageID = $Param{'Message-ID'} || $Self->_MessageIDCreate();

    # split body && header
    my @EmailPlain = split( /\n/, $Param{Email} );
    my $EmailObject = Mail::Internet->new( \@EmailPlain );

    # get sender
    my @Sender   = Mail::Address->parse( $Param{From} );
    my $RealFrom = $Sender[0]->address();

    # add ReSent header (see https://www.ietf.org/rfc/rfc2822.txt A.3. Resent messages)
    my $DateTimeObject = $Kernel::OM->Create('Kernel::System::DateTime');

    my $HeaderObject = $EmailObject->head();
    $HeaderObject->replace( 'Resent-Message-ID', $MessageID );
    $HeaderObject->replace( 'Resent-To',         $Param{To} );
    $HeaderObject->replace( 'Resent-From',       $RealFrom );
    $HeaderObject->replace( 'Resent-Date',       $DateTimeObject->ToEmailTimeStamp() );
    my $Body         = $EmailObject->body();
    my $BodyAsString = '';
    for ( @{$Body} ) {
        $BodyAsString .= $_ . "\n";
    }
    my $HeaderAsString = $HeaderObject->as_string();

    # debug
    if ( $Self->{Debug} > 1 ) {
        my $OldMessageID = $HeaderObject->get('Message-ID') || '??';
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'notice',
            Message  => "Bounced email to '$Param{To}' from '$RealFrom'. "
                . "MessageID => '$OldMessageID';",
        );
    }

    my $Sent = $Self->{Backend}->Send(
        From    => $RealFrom,
        ToArray => [ $Param{To} ],
        Header  => \$HeaderAsString,
        Body    => \$BodyAsString,
    );

    return if !$Sent;

    return ( \$HeaderAsString, \$BodyAsString );
}

=begin Internal:

=cut

sub _EncodeMIMEWords {
    my ( $Self, %Param ) = @_;

    # return if no content is given
    return '' if !defined $Param{Line};

    return MIME::Words::encode_mimewords(
        Encode::encode(
            $Param{Charset},
            $Param{Line},
        ),
        Charset => $Param{Charset},

        # for line length calculation to fold lines (gets ignored by
        # MIME::Words, see pod of MIME::Words)
        Field => $Param{Field},
    );
}

sub _MessageIDCreate {
    my ( $Self, %Param ) = @_;

    my $FQDN = $Kernel::OM->Get('Kernel::Config')->Get('FQDN');

    return '<' . time() . '.' . rand(999999) . '@' . $FQDN . '>';
}

sub _CreateMimeEntity {
    my ( $Self, %Param ) = @_;

    # Get config object.
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    # Build header.
    my %Header;

    my $DefaultHeaders = $ConfigObject->Get('Sendmail::DefaultHeaders') || {};
    if ( IsHashRefWithData($DefaultHeaders) ) {
        %Header = %{$DefaultHeaders};
    }

    if ( IsHashRefWithData( $Param{CustomHeaders} ) ) {
        for my $HeaderName ( sort keys %{ $Param{CustomHeaders} } ) {
            $Header{$HeaderName} = $Param{CustomHeaders}->{$HeaderName};
        }
    }

    ATTRIBUTE:
    for my $Attribute (qw(From To Cc Subject Charset Reply-To)) {
        next ATTRIBUTE if !$Param{$Attribute};
        $Header{$Attribute} = $Param{$Attribute};
    }

    # Check look param/
    if ( $Param{Loop} ) {
        $Header{'X-Loop'}          = 'yes';
        $Header{'Precedence:'}     = 'bulk';
        $Header{'Auto-Submitted:'} = "auto-generated";
    }

    # Do some encodings.
    ATTRIBUTE:
    for my $Attribute (qw(From To Cc Subject)) {
        next ATTRIBUTE if !$Header{$Attribute};
        $Header{$Attribute} = $Self->_EncodeMIMEWords(
            Field   => $Attribute,
            Line    => $Header{$Attribute},
            Charset => $Param{Charset},
        );
    }

    # Check if it's html, add text attachment.
    my $HTMLEmail = 0;
    if ( $Param{MimeType} && $Param{MimeType} =~ /html/i ) {
        $HTMLEmail = 1;

        # Add html as first attachment.
        my $Attach = {
            Content     => $Param{Body},
            ContentType => "text/html; charset=\"$Param{Charset}\"",
            Filename    => '',
        };
        if ( !$Param{Attachment} ) {
            @{ $Param{Attachment} } = ($Attach);
        }
        else {
            @{ $Param{Attachment} } = ( $Attach, @{ $Param{Attachment} } );
        }

        # Remember html body for later comparison.
        $Param{HTMLBody} = $Param{Body};

        # Add ASCII body.
        $Param{MimeType} = 'text/plain';
        $Param{Body}     = $Kernel::OM->Get('Kernel::System::HTMLUtils')->ToAscii(
            String => $Param{Body},
        );

    }

    my $Product = $ConfigObject->Get('Product');
    my $Version = $ConfigObject->Get('Version');

    if ( $ConfigObject->Get('Secure::DisableBanner') ) {

        # Set this to undef to avoid having a value like "MIME-tools 5.507 (Entity 5.507)"
        #   which could lead to the mail being treated as SPAM.
        $Header{'X-Mailer'} = undef;
    }
    else {
        $Header{'X-Mailer'}     = "$Product Mail Service ($Version)";
        $Header{'X-Powered-By'} = 'OTRS (https://otrs.com/)';
    }
    $Header{Type} = $Param{MimeType} || 'text/plain';

    # Define email encoding.
    if ( $Param{Charset} && $Param{Charset} =~ /^iso/i ) {
        $Header{Encoding} = '8bit';
    }
    else {
        $Header{Encoding} = 'quoted-printable';
    }

    # Check if we need to force the encoding.
    if ( $ConfigObject->Get('SendmailEncodingForce') ) {
        $Header{Encoding} = $ConfigObject->Get('SendmailEncodingForce');
    }

    # Check and create message id.
    if ( $Param{'Message-ID'} ) {
        $Header{'Message-ID'} = $Param{'Message-ID'};
    }
    else {
        $Header{'Message-ID'} = $Self->_MessageIDCreate();
    }

    # Add date header.
    my $DateTimeObject = $Kernel::OM->Create('Kernel::System::DateTime');
    $Header{Date} = 'Date: ' . $DateTimeObject->ToEmailTimeStamp();

    # Add organization header.
    my $Organization = $ConfigObject->Get('Organization');
    if ($Organization) {
        $Header{Organization} = $Self->_EncodeMIMEWords(
            Field   => 'Organization',
            Line    => $Organization,
            Charset => $Param{Charset},
        );
    }

    # Get encode object.
    my $EncodeObject = $Kernel::OM->Get('Kernel::System::Encode');

    # build MIME::Entity, Data should be bytes, not utf-8
    # see http://bugs.otrs.org/show_bug.cgi?id=9832
    $EncodeObject->EncodeOutput( \$Param{Body} );
    my $Entity = MIME::Entity->build( %Header, Data => $Param{Body} );

    # Set In-Reply-To and References header
    my $Header = $Entity->head();
    if ( $Param{InReplyTo} ) {
        $Param{'In-Reply-To'} = $Param{InReplyTo};
    }
    KEY:
    for my $Key ( 'In-Reply-To', 'References' ) {
        next KEY if !$Param{$Key};
        $Header->replace( $Key, $Param{$Key} );
    }

    # Add attachments to email.
    if ( $Param{Attachment} ) {
        my $Count    = 0;
        my $PartType = '';
        my @NewAttachments;
        ATTACHMENT:
        for my $Upload ( @{ $Param{Attachment} } ) {

            # Ignore attachment if no content is given.
            next ATTACHMENT if !defined $Upload->{Content};

            # Ignore attachment if no filename is given.
            next ATTACHMENT if !defined $Upload->{Filename};

            # Prepare ContentType for Entity Type. $Upload->{ContentType} has
            # useless `name` parameter, we don't need to send it to the `attach`
            # constructor. For more details see Bug #7879 and MIME::Entity.
            # Note: we should remove `name` attribute only.
            my @ContentTypeTmp = grep { !/\s*name=/ } ( split /;/, $Upload->{ContentType} );
            $Upload->{ContentType} = join ';', @ContentTypeTmp;

            # If it's a html email, add the first attachment as alternative (to show it
            # as alternative content)
            if ($HTMLEmail) {
                $Count++;
                if ( $Count == 1 ) {
                    $Entity->make_multipart('alternative;');
                    $PartType = 'alternative';
                }
                else {

                    # Don't attach duplicate html attachment (aka file-2).
                    next ATTACHMENT if
                        $Upload->{Filename} eq 'file-2'
                        && $Upload->{ContentType} =~ /html/i
                        && $Upload->{Content} eq $Param{HTMLBody};

                    # Skip, but remember all attachments except inline images.
                    if (
                        ( !defined $Upload->{ContentID} )
                        || ( !defined $Upload->{ContentType} || $Upload->{ContentType} !~ /image/i )
                        || (
                            !defined $Upload->{Disposition}
                            || $Upload->{Disposition} ne 'inline'
                        )
                        )
                    {
                        push @NewAttachments, \%{$Upload};
                        next ATTACHMENT;
                    }

                    # Add inline images as related.
                    if ( $PartType ne 'related' ) {
                        $Entity->make_multipart(
                            'related;',
                            Force => 1,
                        );
                        $PartType = 'related';
                    }
                }
            }

            # Do content encode.
            $EncodeObject->EncodeOutput( \$Upload->{Content} );

            # Do filename encode.
            my $Filename = $Self->_EncodeMIMEWords(
                Field   => 'filename',
                Line    => $Upload->{Filename},
                Charset => $Param{Charset},
            );

            # Format content id, leave undefined if no value.
            my $ContentID = $Upload->{ContentID};
            if ( $ContentID && $ContentID !~ /^</ ) {
                $ContentID = '<' . $ContentID . '>';
            }

            # Attach file to email.
            $Entity->attach(
                Filename    => $Filename,
                Data        => $Upload->{Content},
                Type        => $Upload->{ContentType},
                Id          => $ContentID,
                Disposition => $Upload->{Disposition} || 'inline',
                Encoding    => $Upload->{Encoding} || '-SUGGEST',
            );
        }

        # Add all other attachments as multi-part mixed (if we had html body).
        for my $Upload (@NewAttachments) {

            # Make it multi-part mixed.
            if ( $PartType ne 'mixed' ) {
                $Entity->make_multipart(
                    'mixed;',
                    Force => 1,
                );
                $PartType = 'mixed';
            }

            # Do content encode.
            $EncodeObject->EncodeOutput( \$Upload->{Content} );

            # Do filename encode.
            my $Filename = $Self->_EncodeMIMEWords(
                Field   => 'filename',
                Line    => $Upload->{Filename},
                Charset => $Param{Charset},
            );

            my $Encoding = $Upload->{Encoding};
            if ( !$Encoding ) {

                # Attachments of unknown text/* content types might be displayed directly in mail clients
                # because MIME::Entity detects them as 'quoted printable'
                # this causes problems e.g. for pdf files with broken text/pdf content type
                # therefore we fall back to 'base64' in these cases
                if (
                    $Upload->{ContentType} =~ m{ \A text/  }xmsi
                    && $Upload->{ContentType} !~ m{ \A text/ (?: plain | html ) ; }xmsi
                    )
                {
                    $Encoding = 'base64';
                }
                else {
                    $Encoding = '-SUGGEST';
                }
            }

            # Attach file to email (no content id needed).
            $Entity->attach(
                Filename    => $Filename,
                Data        => $Upload->{Content},
                Type        => $Upload->{ContentType},
                Disposition => $Upload->{Disposition} || 'inline',
                Encoding    => $Encoding,
            );
        }
    }

    return $Entity;
}
1;

=end Internal:

=head1 TERMS AND CONDITIONS

This software is part of the OTRS project (L<http://otrs.org/>).

This software comes with ABSOLUTELY NO WARRANTY. For details, see
the enclosed file COPYING for license information (AGPL). If you
did not receive this file, see L<http://www.gnu.org/licenses/agpl.txt>.

=cut
