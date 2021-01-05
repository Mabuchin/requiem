use rustler::types::binary::{Binary, OwnedBinary};
use rustler::types::tuple::make_tuple;
use rustler::types::{Encoder, LocalPid};
use rustler::{Atom, Env, NifResult, ResourceArc};

use once_cell::sync::Lazy;
use parking_lot::{Mutex, RwLock};

use std::convert::TryFrom;
use std::pin::Pin;

use std::collections::HashMap;

use crate::common::{self, atoms};
use crate::config::CONFIGS;

type ModuleName = Vec<u8>;
type BufferSlot = Vec<Mutex<Box<[u8]>>>;
type StreamDataBuffer = RwLock<HashMap<ModuleName, BufferSlot>>;

static STREAM_DATA_BUFFERS: Lazy<StreamDataBuffer> = Lazy::new(|| RwLock::new(HashMap::new()));

pub fn buffer_init(module: &[u8], num: u64, size: usize) {
    let mut buffer_table = STREAM_DATA_BUFFERS.write();
    if !buffer_table.contains_key(module) {
        let mut slot = Vec::new();
        for _ in 0..num {
            let v = unsafe {
                let mut v: Vec<u8> = Vec::with_capacity(size);
                v.set_len(size);
                v
            };
            slot.push(Mutex::new(v.into_boxed_slice()));
        }
        buffer_table.insert(module.to_vec(), slot);
    }
}

pub struct Connection {
    module: Vec<u8>,
    conn: Pin<Box<quiche::Connection>>,
    buf: [u8; 1350],
}

impl Connection {
    pub fn new(module: &[u8], conn: Pin<Box<quiche::Connection>>) -> Self {
        Connection {
            module: module.to_vec(),
            conn: conn,
            buf: [0; 1350],
        }
    }

    pub fn on_packet(&mut self, env: &Env, pid: &LocalPid, packet: &mut [u8]) -> Result<u64, Atom> {
        if !self.conn.is_closed() {
            match self.conn.recv(packet) {
                Ok(_len) => {
                    self.handle_stream(env, pid);
                    self.handle_dgram(env, pid);
                    self.drain(env, pid);
                    Ok(self.next_timeout())
                }

                Err(_) => Err(atoms::system_error()),
            }
        } else {
            Err(atoms::already_closed())
        }
    }

    fn next_timeout(&mut self) -> u64 {
        if let Some(timeout) = self.conn.timeout() {
            let to: u64 = TryFrom::try_from(timeout.as_millis()).unwrap();
            to
        } else {
            60000
        }
    }

    fn handle_stream(&mut self, env: &Env, pid: &LocalPid) {
        if self.conn.is_in_early_data() || self.conn.is_established() {
            let buffer_table = STREAM_DATA_BUFFERS.read();

            if let Some(buf) = buffer_table.get(&self.module) {
                // mitigate lock-wait
                let mut buf = buf[common::random_slot_index(buf.len())].lock();

                for s in self.conn.readable() {
                    while let Ok((len, _fin)) = self.conn.stream_recv(s, &mut buf) {
                        if len > 0 {
                            let mut data = OwnedBinary::new(len).unwrap();
                            data.as_mut_slice().copy_from_slice(&buf[..len]);

                            env.send(
                                pid,
                                make_tuple(
                                    *env,
                                    &[
                                        atoms::__stream_recv__().to_term(*env),
                                        s.encode(*env),
                                        data.release(*env).to_term(*env),
                                    ],
                                ),
                            )
                        }
                    }
                }
            }
        }
    }

    fn stream_send(
        &mut self,
        env: &Env,
        pid: &LocalPid,
        stream_id: u64,
        data: &[u8],
    ) -> Result<u64, Atom> {
        let size = data.len();

        if !self.conn.is_closed() {
            let mut pos = 0;
            loop {
                match self.conn.stream_send(stream_id, &data[pos..], true) {
                    Ok(len) => {
                        pos += len;
                        self.drain(env, pid);
                        if pos >= size {
                            break;
                        }
                    }
                    Err(quiche::Error::Done) => {
                        break;
                    }
                    Err(_) => {
                        return Err(atoms::system_error());
                    }
                };
            }

            Ok(self.next_timeout())
        } else {
            Err(atoms::already_closed())
        }
    }

    fn dgram_send(&mut self, env: &Env, pid: &LocalPid, data: &[u8]) -> Result<u64, Atom> {
        if !self.conn.is_closed() {
            match self.conn.dgram_send(data) {
                Ok(()) => {
                    self.drain(env, pid);
                    Ok(self.next_timeout())
                }

                Err(_) => {
                    return Err(atoms::system_error());
                }
            }
        } else {
            Err(atoms::already_closed())
        }
    }

    fn handle_dgram(&mut self, env: &Env, pid: &LocalPid) {
        if self.conn.is_in_early_data() || self.conn.is_established() {
            while let Ok(len) = self.conn.dgram_recv(&mut self.buf) {
                if len > 0 {
                    let mut data = OwnedBinary::new(len).unwrap();
                    data.as_mut_slice().copy_from_slice(&self.buf[..len]);

                    env.send(
                        pid,
                        make_tuple(
                            *env,
                            &[
                                atoms::__dgram_recv__().to_term(*env),
                                data.release(*env).to_term(*env),
                            ],
                        ),
                    );
                }
            }
        }
    }

    pub fn on_timeout(&mut self, env: &Env, pid: &LocalPid) -> Result<u64, Atom> {
        if !self.conn.is_closed() {
            self.conn.on_timeout();
            self.drain(env, pid);
            Ok(self.next_timeout())
        } else {
            Err(atoms::already_closed())
        }
    }

    pub fn is_closed(&self) -> bool {
        self.conn.is_closed()
    }

    pub fn close(
        &mut self,
        env: &Env,
        pid: &LocalPid,
        app: bool,
        err: u64,
        reason: &[u8],
    ) -> Result<(), Atom> {
        if !self.conn.is_closed() {
            match self.conn.close(app, err, reason) {
                Ok(()) => {
                    self.drain(env, pid);
                    Ok(())
                }

                Err(quiche::Error::Done) => Ok(()),

                Err(_) => Err(atoms::system_error()),
            }
        } else {
            Err(atoms::already_closed())
        }
    }

    fn drain(&mut self, env: &Env, pid: &LocalPid) {
        loop {
            match self.conn.send(&mut self.buf) {
                Ok(len) => {
                    let mut data = OwnedBinary::new(len).unwrap();
                    data.as_mut_slice().copy_from_slice(&self.buf[..len]);

                    env.send(
                        pid,
                        make_tuple(
                            *env,
                            &[
                                atoms::__drain__().to_term(*env),
                                data.release(*env).to_term(*env),
                            ],
                        ),
                    );
                }

                Err(quiche::Error::Done) => {
                    break;
                }

                Err(_) => {
                    // XXX should return error?
                    self.conn.close(false, 0x1, b"fail").ok();
                    break;
                }
            };
        }
    }
}

pub struct LockedConnection {
    conn: Mutex<Connection>,
}

impl LockedConnection {
    pub fn new(module: &[u8], raw: Pin<Box<quiche::Connection>>) -> Self {
        LockedConnection {
            conn: Mutex::new(Connection::new(module, raw)),
        }
    }
}

#[rustler::nif]
pub fn connection_accept(
    module: Binary,
    scid: Binary,
    odcid: Binary,
) -> NifResult<(Atom, ResourceArc<LockedConnection>)> {
    let module = module.as_slice();
    let scid = scid.as_slice();
    let odcid = odcid.as_slice();

    let config_table = CONFIGS.read();

    if let Some(c) = config_table.get(module) {
        let mut c = c.lock();

        match quiche::accept(scid, Some(odcid), &mut c) {
            Ok(conn) => Ok((
                atoms::ok(),
                ResourceArc::new(LockedConnection::new(module, conn)),
            )),

            Err(_) => Err(common::error_term(atoms::system_error())),
        }
    } else {
        Err(common::error_term(atoms::not_found()))
    }
}

#[rustler::nif]
pub fn connection_close(
    env: Env,
    pid: LocalPid,
    conn: ResourceArc<LockedConnection>,
    app: bool,
    err: u64,
    reason: Binary,
) -> NifResult<Atom> {
    let mut conn = conn.conn.lock();

    match conn.close(&env, &pid, app, err, reason.as_slice()) {
        Ok(_) => Ok(atoms::ok()),
        Err(reason) => Err(common::error_term(reason)),
    }
}

#[rustler::nif]
pub fn connection_is_closed(conn: ResourceArc<LockedConnection>) -> bool {
    let conn = conn.conn.lock();
    conn.is_closed()
}

#[rustler::nif]
pub fn connection_on_packet(
    env: Env,
    pid: LocalPid,
    conn: ResourceArc<LockedConnection>,
    packet: Binary,
) -> NifResult<(Atom, u64)> {
    let mut conn = conn.conn.lock();
    let mut packet = packet.to_owned().unwrap();

    match conn.on_packet(&env, &pid, &mut packet.as_mut_slice()) {
        Ok(next_timeout) => Ok((atoms::ok(), next_timeout)),
        Err(reason) => Err(common::error_term(reason)),
    }
}

#[rustler::nif]
pub fn connection_on_timeout(
    env: Env,
    pid: LocalPid,
    conn: ResourceArc<LockedConnection>,
) -> NifResult<(Atom, u64)> {
    let mut conn = conn.conn.lock();

    match conn.on_timeout(&env, &pid) {
        Ok(next_timeout) => Ok((atoms::ok(), next_timeout)),
        Err(reason) => Err(common::error_term(reason)),
    }
}

#[rustler::nif]
pub fn connection_stream_send(
    env: Env,
    pid: LocalPid,
    conn: ResourceArc<LockedConnection>,
    stream_id: u64,
    data: Binary,
) -> NifResult<(Atom, u64)> {
    let mut conn = conn.conn.lock();
    match conn.stream_send(&env, &pid, stream_id, data.as_slice()) {
        Ok(next_timeout) => Ok((atoms::ok(), next_timeout)),
        Err(reason) => Err(common::error_term(reason)),
    }
}

#[rustler::nif]
pub fn connection_dgram_send(
    env: Env,
    pid: LocalPid,
    conn: ResourceArc<LockedConnection>,
    data: Binary,
) -> NifResult<(Atom, u64)> {
    let mut conn = conn.conn.lock();
    match conn.dgram_send(&env, &pid, data.as_slice()) {
        Ok(next_timeout) => Ok((atoms::ok(), next_timeout)),
        Err(reason) => Err(common::error_term(reason)),
    }
}

pub fn on_load(env: Env) -> bool {
    rustler::resource!(LockedConnection, env);
    true
}
