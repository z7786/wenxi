// Derived from goed2k internal/upnp/upnp.go and internal/upnp/igd_service.go.
//
// Copyright (C) 2014 The Syncthing Authors.
//
// Ported from https://github.com/syncthing/syncthing/tree/master/lib/upnp
// Adapted from https://github.com/jackpal/Taipei-Torrent/blob/dd88a8bfac6431c01d959ce3c745e74b8a911793/IGD.go
// Copyright (c) 2010 Jack Palevich (https://github.com/jackpal/Taipei-Torrent/blob/dd88a8bfac6431c01d959ce3c745e74b8a911793/LICENSE)
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//    * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//    * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//    * Neither the name of Google Inc. nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

package nat

import (
	"bufio"
	"bytes"
	"context"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"runtime"
	"slices"
	"strings"
	"sync"
	"time"
)

const (
	searchWindow   = 3 * time.Second
	maxResponseLen = 1 << 20
)

var gatewayTypes = []string{
	"urn:schemas-upnp-org:device:InternetGatewayDevice:1",
	"urn:schemas-upnp-org:device:InternetGatewayDevice:2",
}

type service struct {
	controlURL string
	urn        string
	localIP    netip.Addr
}

type upnpService struct {
	Type       string `xml:"serviceType"`
	ControlURL string `xml:"controlURL"`
}

type upnpDevice struct {
	DeviceType string        `xml:"deviceType"`
	Devices    []upnpDevice  `xml:"deviceList>device"`
	Services   []upnpService `xml:"serviceList>service"`
}

type upnpRoot struct {
	Device upnpDevice `xml:"device"`
}

// probeLocations sends an SSDP M-SEARCH for IGDv1 and IGDv2 on every
// multicast interface and returns the distinct device description URLs that
// answer within the search window or before ctx ends.
func probeLocations(ctx context.Context) []string {
	interfaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	deadline := time.Now().Add(searchWindow)
	if ctxDeadline, ok := ctx.Deadline(); ok && ctxDeadline.Before(deadline) {
		deadline = ctxDeadline
	}

	results := make(chan string)
	// wg closes results once every interface's search is done.
	var wg sync.WaitGroup
	for _, intf := range interfaces {
		// Interface flags seem to always be 0 on Windows
		if runtime.GOOS != "windows" && (intf.Flags&net.FlagUp == 0 || intf.Flags&net.FlagMulticast == 0) {
			continue
		}
		for _, deviceType := range gatewayTypes {
			wg.Add(1)
			go func() {
				defer wg.Done()
				probeInterface(ctx, intf, deviceType, deadline, results)
			}()
		}
	}
	go func() {
		wg.Wait()
		close(results)
	}()

	var locations []string
	for location := range results {
		if !slices.Contains(locations, location) {
			locations = append(locations, location)
		}
	}
	return locations
}

func probeInterface(ctx context.Context, intf net.Interface, deviceType string, deadline time.Time, results chan<- string) {
	ssdp := &net.UDPAddr{IP: net.IPv4(239, 255, 255, 250), Port: 1900}
	// MX is the longest a device may wait before answering; 2 s keeps every
	// answer inside the 3 s search window.
	search := strings.ReplaceAll(fmt.Sprintf(`M-SEARCH * HTTP/1.1
HOST: 239.255.255.250:1900
ST: %s
MAN: "ssdp:discover"
MX: 2
USER-AGENT: Kelpie

`, deviceType), "\n", "\r\n")

	socket, err := net.ListenMulticastUDP("udp4", &intf, &net.UDPAddr{IP: ssdp.IP})
	if err != nil {
		return
	}
	defer socket.Close()
	stop := context.AfterFunc(ctx, func() { socket.Close() })
	defer stop()
	if err := socket.SetDeadline(deadline); err != nil {
		return
	}
	if _, err := socket.WriteTo([]byte(search), ssdp); err != nil {
		return
	}

	buffer := make([]byte, 65536)
	for {
		n, _, err := socket.ReadFrom(buffer)
		if err != nil {
			return
		}
		location, err := parseSearchResponse(deviceType, buffer[:n])
		if err != nil {
			continue
		}
		results <- location
	}
}

func parseSearchResponse(deviceType string, data []byte) (string, error) {
	response, err := http.ReadResponse(bufio.NewReader(bytes.NewReader(data)), &http.Request{})
	if err != nil {
		return "", err
	}
	response.Body.Close()
	if st := response.Header.Get("St"); st != deviceType {
		return "", errors.New("nat: unrecognized UPnP device of type " + st)
	}
	location := response.Header.Get("Location")
	if location == "" {
		return "", errors.New("nat: invalid IGD response: no location specified")
	}
	return location, nil
}

// fetchServices reads the device description at location and returns its
// WANIPConnection and WANPPPConnection services.
func fetchServices(ctx context.Context, location string) ([]service, error) {
	base, err := url.Parse(location)
	if err != nil {
		return nil, err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, location, nil)
	if err != nil {
		return nil, err
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode >= 400 {
		return nil, fmt.Errorf("nat: [%s] bad status code: %s", location, response.Status)
	}
	var root upnpRoot
	if err := xml.NewDecoder(io.LimitReader(response.Body, maxResponseLen)).Decode(&root); err != nil {
		return nil, fmt.Errorf("nat: [%s] %w", location, err)
	}

	// The mapping's NewInternalClient must be the address this host uses
	// towards the gateway, which only the socket's local end reveals.
	localIP, err := probeLocalIP(ctx, base.Host)
	if err != nil {
		return nil, err
	}
	return parseServices(base, localIP, root.Device)
}

func probeLocalIP(ctx context.Context, host string) (netip.Addr, error) {
	ctx, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	conn, err := (&net.Dialer{}).DialContext(ctx, "tcp", host)
	if err != nil {
		return netip.Addr{}, err
	}
	defer conn.Close()
	return conn.LocalAddr().(*net.TCPAddr).AddrPort().Addr().Unmap(), nil
}

// parseServices takes every WANIPConnection and WANPPPConnection under the
// gateway whatever version each level names, since routers mix IGD:1 and
// IGD:2 parts (aMule UPnPBase.cpp TypeMatchesIgnoringVersion).
func parseServices(base *url.URL, localIP netip.Addr, root upnpDevice) ([]service, error) {
	if !matchType(root.DeviceType, "device:InternetGatewayDevice") {
		return nil, fmt.Errorf("nat: [%s] malformed root device description: not an InternetGatewayDevice", base)
	}
	var services []service
	for _, wan := range root.Devices {
		if !matchType(wan.DeviceType, "device:WANDevice") {
			continue
		}
		for _, connection := range wan.Devices {
			if !matchType(connection.DeviceType, "device:WANConnectionDevice") {
				continue
			}
			for _, s := range connection.Services {
				isConnection := matchType(s.Type, "service:WANIPConnection") || matchType(s.Type, "service:WANPPPConnection")
				if !isConnection || s.ControlURL == "" {
					continue
				}
				controlURL, err := toControlURL(base, s.ControlURL)
				if err != nil {
					continue
				}
				services = append(services, service{controlURL: controlURL, urn: s.Type, localIP: localIP})
			}
		}
	}
	if len(services) == 0 {
		return nil, fmt.Errorf("nat: [%s] malformed device description: no compatible service descriptions found", base)
	}
	return services, nil
}

// matchType tells whether a UPnP type URN is of kind, such as
// "device:WANDevice", in any version. The colon after kind keeps
// WANIPConnection from matching WANIPConnectionFoo.
func matchType(urn, kind string) bool {
	prefix := "urn:schemas-upnp-org:" + kind + ":"
	return len(urn) > len(prefix) && strings.EqualFold(urn[:len(prefix)], prefix)
}

// toControlURL keeps the description's scheme and host even for an absolute
// controlURL: some routers advertise a host they are not reachable at.
func toControlURL(base *url.URL, controlURL string) (string, error) {
	reference, err := url.Parse(controlURL)
	if err != nil {
		return "", err
	}
	resolved := base.ResolveReference(reference)
	resolved.Scheme = base.Scheme
	resolved.Host = base.Host
	return resolved.String(), nil
}

func (s service) addMapping(ctx context.Context, m mapping, description string) error {
	body := fmt.Sprintf(`<u:AddPortMapping xmlns:u="%s">
	<NewRemoteHost></NewRemoteHost>
	<NewExternalPort>%d</NewExternalPort>
	<NewProtocol>%s</NewProtocol>
	<NewInternalPort>%d</NewInternalPort>
	<NewInternalClient>%s</NewInternalClient>
	<NewEnabled>1</NewEnabled>
	<NewPortMappingDescription>%s</NewPortMappingDescription>
	<NewLeaseDuration>0</NewLeaseDuration>
	</u:AddPortMapping>`, s.urn, m.port, m.protocol, m.port, s.localIP, toXMLText(description))
	_, err := s.requestSOAP(ctx, "AddPortMapping", body)
	return err
}

func (s service) deleteMapping(ctx context.Context, m mapping) error {
	body := fmt.Sprintf(`<u:DeletePortMapping xmlns:u="%s">
	<NewRemoteHost></NewRemoteHost>
	<NewExternalPort>%d</NewExternalPort>
	<NewProtocol>%s</NewProtocol>
	</u:DeletePortMapping>`, s.urn, m.port, m.protocol)
	_, err := s.requestSOAP(ctx, "DeletePortMapping", body)
	return err
}

func (s service) fetchExternalIP(ctx context.Context) (netip.Addr, error) {
	response, err := s.requestSOAP(ctx, "GetExternalIPAddress", fmt.Sprintf(`<u:GetExternalIPAddress xmlns:u="%s" />`, s.urn))
	if err != nil {
		return netip.Addr{}, err
	}
	var envelope struct {
		IP string `xml:"Body>GetExternalIPAddressResponse>NewExternalIPAddress"`
	}
	if err := xml.Unmarshal(response, &envelope); err != nil {
		return netip.Addr{}, err
	}
	ip, err := netip.ParseAddr(strings.TrimSpace(envelope.IP))
	if err != nil {
		return netip.Addr{}, err
	}
	if ip.IsUnspecified() {
		return netip.Addr{}, errors.New("nat: gateway reports no external address")
	}
	return ip.Unmap(), nil
}

func (s service) requestSOAP(ctx context.Context, action, message string) ([]byte, error) {
	body := fmt.Sprintf(`<?xml version="1.0" ?>
	<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
	<s:Body>%s</s:Body>
	</s:Envelope>
`, message)
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, s.controlURL, strings.NewReader(body))
	if err != nil {
		return nil, err
	}
	request.Close = true
	request.Header.Set("Content-Type", `text/xml; charset="utf-8"`)
	request.Header.Set("User-Agent", "Kelpie")
	// Enforce capitalization in header-entry for sensitive routers. See syncthing issue #1696
	request.Header["SOAPAction"] = []string{fmt.Sprintf(`"%s#%s"`, s.urn, action)}
	request.Header.Set("Connection", "Close")
	request.Header.Set("Cache-Control", "no-cache")
	request.Header.Set("Pragma", "no-cache")

	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, maxResponseLen))
	if err != nil {
		return nil, err
	}
	if response.StatusCode >= 400 {
		var fault struct {
			Code        int    `xml:"Body>Fault>detail>UPnPError>errorCode"`
			Description string `xml:"Body>Fault>detail>UPnPError>errorDescription"`
		}
		if xml.Unmarshal(data, &fault) == nil && fault.Code != 0 {
			return nil, fmt.Errorf("nat: %s: UPnP error %d %s", action, fault.Code, fault.Description)
		}
		return nil, fmt.Errorf("nat: %s: %s", action, response.Status)
	}
	return data, nil
}

func toXMLText(text string) string {
	var buffer strings.Builder
	xml.EscapeText(&buffer, []byte(text))
	return buffer.String()
}
