"""Set-up local Universe"""

from subprocess import call

from shakedown import *

PACKAGE_NAME = 'jenkins'
WAIT_TIME_IN_SECS = 300

agents = get_agents()


def test_copy_docker_image():
    """Copy the Docker image to Marathon nodes
    """
    for host in agents:
        copy_file_to_agent(host, PACKAGE_NAME + '.tar')
        run_command_on_agent(host, 'docker load -i ' + PACKAGE_NAME + '.tar')

    copy_file_to_master(PACKAGE_NAME + '.tar')
    run_command_on_master('docker load -i ' + PACKAGE_NAME + '.tar')


def test_install_local_universe():
    """Install the local Universe and set it as the default package repository
    """
    for host in agents:
        copy_file_to_agent(host, 'local-universe.tar')
        run_command_on_agent(host, 'docker load -i local-universe.tar')

    copy_file_to_master('local-universe.tar')
    run_command_on_master('docker load -i local-universe.tar')

    run_dcos_command('marathon app add universe/docker/server/target/marathon.json')

    end_time = time.time() + WAIT_TIME_IN_SECS
    found = False
    while time.time() < end_time:
        found = get_marathon_task('universe')
        if found and found['state'] == 'TASK_RUNNING':
            time.sleep(60)
            break
        time.sleep(1)

    assert found, 'Service did not register with DCOS'

    if not found:
        run_dcos_command('marathon app remove universe')

    add_package_repo('local-universe', 'http://universe.marathon.mesos:8085/repo', 0)
