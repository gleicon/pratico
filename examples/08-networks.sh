#!/usr/bin/env bash
# One NIC per VM: each network is another address on eth0, with no limit on how many.
. "$(dirname "$0")/lib.sh"
nets="pratico-example-n1 pratico-example-n2 pratico-example-n3 pratico-example-n4 pratico-example-n5"
cleanup() {
    docker rm -f pratico-example-multi pratico-example-peer >/dev/null 2>&1 || true
    for n in $nets; do docker network rm "$n" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT
cleanup

step "five networks, one container on all of them"
for n in $nets; do docker network create "$n" >/dev/null; done
docker run -d --name pratico-example-multi --network pratico-example-n1 alpine sleep 300 >/dev/null
for n in pratico-example-n2 pratico-example-n3 pratico-example-n4 pratico-example-n5; do
    docker network connect "$n" pratico-example-multi
done
docker exec pratico-example-multi ip -4 -o addr show eth0 | awk '{print $2, $4}'

step "the default route and DNS follow the first network"
docker exec pratico-example-multi ip route | grep ^default
docker exec pratico-example-multi cat /etc/resolv.conf

step "a peer on n3 reaches the container by name"
docker run -d --name pratico-example-peer --network pratico-example-n3 alpine sleep 300 >/dev/null
docker exec pratico-example-peer ping -c1 -W2 pratico-example-multi | grep "packets received"

step "leaving n1 moves the default route and DNS to the next network"
docker network disconnect pratico-example-n1 pratico-example-multi
docker exec pratico-example-multi ip route | grep ^default
docker exec pratico-example-multi cat /etc/resolv.conf
docker exec pratico-example-multi nslookup pratico-example-peer >/dev/null && echo "names still resolve"
