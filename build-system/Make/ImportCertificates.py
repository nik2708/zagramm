import os
import sys
import argparse

from BuildEnvironment import run_executable_with_output

def import_certificates(certificatesPath):
    if not os.path.exists(certificatesPath):
        print('{} does not exist'.format(certificatesPath))
        sys.exit(1)

    keychain_name = 'temp.keychain'
    keychain_password = 'secret'

    home = os.path.expanduser('~')
    keychain_path = home + '/Library/Keychains/' + keychain_name

    # Start fresh: remove previous temp.keychain if any
    if os.path.exists(keychain_path):
        run_executable_with_output('security', arguments=['delete-keychain', keychain_path], check_result=False)

    run_executable_with_output('security', arguments=[
        'create-keychain',
        '-p',
        keychain_password,
        keychain_path
    ], check_result=True)

    run_executable_with_output('security', arguments=['set-keychain-settings', keychain_path], check_result=False)
    run_executable_with_output('security', arguments=['unlock-keychain', '-p', keychain_password, keychain_path], check_result=True)

    # Explicit keychain search list: temp.keychain + login, passed as separate arguments.
    # (The original script passed the whole multi-line `list-keychains` output as one
    # argument, which does not put temp.keychain into the search list reliably on
    # recent macOS, so codesign cannot find imported identities.)
    login_keychain_path = home + '/Library/Keychains/login.keychain-db'
    search_list = [keychain_path]
    if os.path.exists(login_keychain_path):
        search_list.append(login_keychain_path)
    run_executable_with_output('security', arguments=['list-keychains', '-d', 'user', '-s'] + search_list, check_result=True)
    run_executable_with_output('security', arguments=['default-keychain', '-d', 'user', '-s', keychain_path], check_result=False)

    for file_name in sorted(os.listdir(certificatesPath)):
        file_path = certificatesPath + '/' + file_name
        if file_name.endswith('.p12') or file_name.endswith('.cer'):
            run_executable_with_output('security', arguments=[
                'import',
                file_path,
                '-k',
                keychain_path,
                '-P',
                '',
                '-T',
                '/usr/bin/codesign',
                '-T',
                '/usr/bin/security'
            ], check_result=False)

    if os.path.exists('build-system/AppleWWDRCAG3.cer'):
        run_executable_with_output('security', arguments=[
            'import',
            'build-system/AppleWWDRCAG3.cer',
            '-k',
            keychain_path,
            '-P',
            '',
            '-T',
            '/usr/bin/codesign',
            '-T',
            '/usr/bin/security'
        ], check_result=False)

    run_executable_with_output('security', arguments=[
        'set-key-partition-list',
        '-S',
        'apple-tool:,apple:,codesign:',
        '-k',
        keychain_password,
        keychain_path
    ], check_result=True)

    # Ghostgram debug: verify the search list and visible identities
    print('=== keychain search list ===')
    output = run_executable_with_output('security', arguments=['list-keychains', '-d', 'user'], check_result=False)
    print(output)
    print('=== codesigning identities ===')
    output = run_executable_with_output('security', arguments=['find-identity', '-v', '-p', 'codesigning'], check_result=False)
    print(output)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(prog='build')

    parser.add_argument(
        '--path',
        required=True,
        help='Path to certificates.'
    )

    if len(sys.argv) < 2:
        parser.print_help()
        sys.exit(1)

    args = parser.parse_args()

    import_certificates(args.path)
