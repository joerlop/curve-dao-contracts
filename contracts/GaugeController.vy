# The contract which controls gauges and issuance of coins through those

# 7 * 86400 seconds - all future times are rounded by week
WEEK: constant(uint256) = 604800

# Cannot change weight votes more often than once in 10 days
WEIGHT_VOTE_DELAY: constant(uint256) = 10 * 86400


struct Point:
    bias: int128
    slope: int128  # - dweight / dt
    ts: uint256

struct VotedSlope:
    slope: int128
    power: int128
    end: uint256


interface CRV20:
    def start_epoch_time_write() -> uint256: nonpayable
    def start_epoch_time() -> uint256: view


interface VotingEscrow:
    def get_last_user_slope(addr: address) -> int128: view
    def locked__end(addr: address) -> uint256: view


event CommitOwnership:
    admin: address

event ApplyOwnership:
    admin: address

event NewTypeWeight:
    type_id: int128
    time: uint256
    weight: uint256
    total_weight: uint256

event NewGaugeWeight:
    gauge_address: address
    time: uint256
    weight: uint256
    total_weight: uint256

event VoteForGauge:
    time: uint256
    user: address
    gauge_addr: address
    weight: int128


MULTIPLIER: constant(uint256) = 10 ** 18

admin: public(address)  # Can and will be a smart contract
future_admin: public(address)  # Can and will be a smart contract

token: public(address)  # CRV token
voting_escrow: public(address)  # Voting escrow

# Gauge parameters
# All numbers are "fixed point" on the basis of 1e18
n_gauge_types: public(int128)
n_gauges: public(int128)
gauge_type_names: public(HashMap[int128, String[64]])

# Every time a weight or epoch changes, period increases
# The idea is: relative weights are guaranteed to not change within the period
# Period 0 is reserved for "not started" (b/c default value in maps)
# Period is guaranteed to not have a change of epoch (e.g. mining rate) in the
# middle of it
period: public(int128)
period_timestamp: public(HashMap[int128, uint256])

# Needed for enumeration
gauges: public(HashMap[int128, address])

# we increment values by 1 prior to storing them here so we can rely on a value
# of zero as meaning the gauge has not been set
gauge_types_: HashMap[address, int128]

gauge_weights: HashMap[address, HashMap[int128, uint256]]  # address -> period -> weight
type_weights: HashMap[int128, HashMap[int128, uint256]]  # type_id -> period -> weight
weight_sums_per_type: HashMap[int128, HashMap[int128, uint256]]  # type_id -> period -> weight
total_weight: HashMap[int128, uint256]  # period -> total_weight

type_last: HashMap[int128, int128]  # Last period for type update type_id -> period
gauge_last: HashMap[address, int128]  # Last period for gauge update gauge_addr -> period
# Total is always at the last updated state

last_epoch_time: public(uint256)

vote_points: public(HashMap[address, Point])  # gauge_addr -> Point
vote_enacted_at: public(HashMap[address, uint256])  # gauge_addr -> timestamp
vote_slope_changes: public(HashMap[address, HashMap[uint256, int128]])  # gauge_addr -> time -> slope
vote_bias_changes: public(HashMap[address, HashMap[uint256, int128]])  # gauge_addr -> time -> bias
vote_user_slopes: public(HashMap[address, HashMap[address, VotedSlope]])  # user -> gauge_addr -> VotedSlope
vote_user_power: public(HashMap[address, int128])  # Total vote power used by user
last_user_vote: public(HashMap[address, HashMap[address, uint256]])  # Last user vote's timestamp for each gauge address


@external
def __init__(_token: address, _voting_escrow: address):
    self.admin = msg.sender
    self.token = _token
    self.voting_escrow = _voting_escrow
    self.period_timestamp[0] = block.timestamp
    self.last_epoch_time = CRV20(_token).start_epoch_time_write()


@external
def commit_transfer_ownership(addr: address):
    """
    @notice Transfer ownership of GaugeController to `addr`
    @param addr Address to have ownership transferred to
    """
    assert msg.sender == self.admin
    self.future_admin = addr
    log CommitOwnership(addr)


@external
def apply_transfer_ownership():
    assert msg.sender == self.admin
    _admin: address = self.future_admin
    self.admin = _admin
    log ApplyOwnership(_admin)


@external
@view
def gauge_types(_addr: address) -> int128:
    gauge_type: int128 = self.gauge_types_[_addr]
    assert gauge_type != 0

    return gauge_type - 1


@internal
def change_epoch(_p: int128) -> (int128, bool):
    # Handle change of epoch
    # If epoch change happened after the last point but before current-
    #     insert a new period
    # else use the current period for both weght and epoch change
    p: int128 = _p
    let: uint256 = CRV20(self.token).start_epoch_time_write()
    epoch_changed: bool = (let > self.period_timestamp[p]) and (let <= block.timestamp)
    if epoch_changed:
        p += 1
        self.period_timestamp[p] = let
    return (p, epoch_changed)


@external
def period_write() -> int128:
    p: int128 = self.period
    epoch_changed: bool = False
    p, epoch_changed = self.change_epoch(p)
    if epoch_changed:
        self.period = p
        self.total_weight[p] = self.total_weight[p-1]
    return p


@external
def add_gauge(addr: address, gauge_type: int128, weight: uint256 = 0):
    """
    @notice Add gauge `addr` of type `gauge_type` with weight `weight`
    @param addr Gauge address
    @param gauge_type Gauge type
    @param weight Gauge weight
    """
    assert msg.sender == self.admin
    assert (gauge_type >= 0) and (gauge_type < self.n_gauge_types)
    assert self.gauge_types_[addr] == 0  # dev: cannot add the same gauge twice

    n: int128 = self.n_gauges
    self.n_gauges = n + 1
    self.gauges[n] = addr

    self.gauge_types_[addr] = gauge_type + 1

    if weight > 0:
        p: int128 = self.period
        epoch_changed: bool = False
        p, epoch_changed = self.change_epoch(p)
        p += 1
        self.period = p
        l: int128 = self.type_last[gauge_type]
        self.type_last[gauge_type] = p
        self.gauge_last[addr] = p
        old_sum: uint256 = self.weight_sums_per_type[gauge_type][l]
        _type_weight: uint256 = self.type_weights[gauge_type][l]
        if l > 0:
            # Fill historic type weights and sums
            _p: int128 = l
            for i in range(500):  # If higher (unlikely) - 0 weights
                _p += 1
                if _p == p:
                    break
                self.type_weights[gauge_type][_p] = _type_weight
                self.weight_sums_per_type[gauge_type][_p] = old_sum
        self.type_weights[gauge_type][p] = _type_weight
        self.gauge_weights[addr][p] = weight
        self.weight_sums_per_type[gauge_type][p] = weight + old_sum
        if epoch_changed:
            self.total_weight[p-1] = self.total_weight[p-2]
        self.total_weight[p] = self.total_weight[p-1] + _type_weight * weight
        self.period_timestamp[p] = block.timestamp


@external
@view
def gauge_relative_weight(addr: address, _period: int128=-1) -> uint256:
    p: int128 = _period
    if _period < 0:
        p = self.period
    _total_weight: uint256 = self.total_weight[p]
    if _total_weight > 0:
        gauge_type: int128 = self.gauge_types_[addr] - 1
        tl: int128 = self.type_last[gauge_type]
        gl: int128 = self.gauge_last[addr]
        return MULTIPLIER * self.type_weights[gauge_type][tl] * self.gauge_weights[addr][gl] / _total_weight
    else:
        return 0


@external
def gauge_relative_weight_write(addr: address, _period: int128=-1) -> uint256:
    """
    Same as gauge_relative_weight(), but also fill all the unfilled values
    for type and gauge records
    """
    p: int128 = _period
    if _period < 0:
        p = self.period
        epoch_changed: bool = False
        p, epoch_changed = self.change_epoch(p)
        if epoch_changed:
            self.total_weight[p] = self.total_weight[p-1]
            self.period = p
    else:
        assert p <= self.period
    _total_weight: uint256 = self.total_weight[p]
    if _total_weight > 0:
        gauge_type: int128 = self.gauge_types_[addr] - 1
        tl: int128 = self.type_last[gauge_type]
        gl: int128 = self.gauge_last[addr]
        if p > tl and tl > 0:
            _type_weight: uint256 = self.type_weights[gauge_type][tl]
            old_sum: uint256 = self.weight_sums_per_type[gauge_type][tl]
            for i in range(500):
                tl += 1
                self.type_weights[gauge_type][tl] = _type_weight
                self.weight_sums_per_type[gauge_type][tl] = old_sum
                if tl == p:
                    break
            self.type_last[gauge_type] = p
        if p > gl and gl > 0:
            old_gauge_weight: uint256 = self.gauge_weights[addr][gl]
            for i in range(500):
                gl += 1
                self.gauge_weights[addr][gl] = old_gauge_weight
                if gl == p:
                    break
            self.gauge_last[addr] = p
        return MULTIPLIER * self.type_weights[gauge_type][tl] * self.gauge_weights[addr][gl] / _total_weight
    else:
        return 0


@internal
def _change_type_weight(type_id: int128, weight: uint256):
    p: int128 = self.period
    epoch_changed: bool = False
    p, epoch_changed = self.change_epoch(p)
    if epoch_changed:
        self.total_weight[p] = self.total_weight[p-1]
    p += 1
    self.period = p
    l: int128 = self.type_last[type_id]
    self.type_last[type_id] = p
    old_weight: uint256 = self.type_weights[type_id][l]
    old_sum: uint256 = self.weight_sums_per_type[type_id][l]
    _total_weight: uint256 = self.total_weight[p-1]

    if l > 0:
        # Fill historic type weights and sums
        _p: int128 = l
        for i in range(500):  # If higher (unlikely) - 0 weights
            _p += 1
            if _p == p:
                break
            self.type_weights[type_id][_p] = old_weight
            self.weight_sums_per_type[type_id][_p] = old_sum

    _total_weight = _total_weight + old_sum * weight - old_sum * old_weight
    self.total_weight[p] = _total_weight
    self.type_weights[type_id][p] = weight
    self.weight_sums_per_type[type_id][p] = old_sum

    self.period_timestamp[p] = block.timestamp

    log NewTypeWeight(type_id, block.timestamp, weight, _total_weight)


@external
def add_type(_name: String[64], weight: uint256 = 0):
    """
    @notice Add gauge type with name `_name` and weight `weight`
    @param _name Name of gauge type
    @param weight Weight of gauge type
    """
    assert msg.sender == self.admin
    type_id: int128 = self.n_gauge_types
    self.gauge_type_names[type_id] = _name
    self.n_gauge_types = type_id + 1
    if weight != 0:
        self._change_type_weight(type_id, weight)


@external
def change_type_weight(type_id: int128, weight: uint256):
    """
    @notice Change gauge type `type_id` weight to `weight`
    @param type_id Gauge type id
    @param weight New Gauge weight
    """
    assert msg.sender == self.admin
    self._change_type_weight(type_id, weight)


@internal
def _change_gauge_weight(addr: address, weight: uint256):
    # Fill weight from gauge_last to now, type_sums from type_last till now, total
    gauge_type: int128 = self.gauge_types_[addr] - 1
    p: int128 = self.period
    epoch_changed: bool = False
    p, epoch_changed = self.change_epoch(p)
    if epoch_changed:
        self.total_weight[p] = self.total_weight[p-1]
    p += 1
    self.period = p
    gl: int128 = self.gauge_last[addr]
    tl: int128 = self.type_last[gauge_type]
    old_gauge_weight: uint256 = self.gauge_weights[addr][gl]
    type_weight: uint256 = self.type_weights[gauge_type][tl]
    old_sum: uint256 = self.weight_sums_per_type[gauge_type][tl]
    _total_weight: uint256 = self.total_weight[p-1]

    if tl > 0:
        _p: int128 = tl
        for i in range(500):
            _p += 1
            if _p == p:
                break
            self.type_weights[gauge_type][_p] = type_weight
            self.weight_sums_per_type[gauge_type][_p] = old_sum
    self.type_weights[gauge_type][p] = type_weight
    self.type_last[gauge_type] = p

    if gl > 0:
        _p: int128 = gl
        for i in range(500):
            _p += 1
            if _p == p:
                break
            self.gauge_weights[addr][_p] = old_gauge_weight
    self.gauge_last[addr] = p

    new_sum: uint256 = old_sum + weight - old_gauge_weight
    self.gauge_weights[addr][p] = weight
    self.weight_sums_per_type[gauge_type][p] = new_sum
    _total_weight = _total_weight + new_sum * type_weight - old_sum * type_weight
    self.total_weight[p] = _total_weight

    self.period_timestamp[p] = block.timestamp

    log NewGaugeWeight(addr, block.timestamp, weight, _total_weight)


@external
def change_gauge_weight(addr: address, weight: uint256):
    assert msg.sender == self.admin
    self._change_gauge_weight(addr, weight)


@internal
def _enact_vote(_gauge_addr: address):
    ts: uint256 = self.vote_enacted_at[_gauge_addr]
    if (ts + WEEK) / WEEK * WEEK <= block.timestamp:
        # Update vote_point
        vote_point: Point = self.vote_points[_gauge_addr]
        if vote_point.ts == 0:
            vote_point.ts = block.timestamp
        for i in range(500):
            next_ts: uint256 = (vote_point.ts + WEEK) / WEEK * WEEK
            dslope: int128 = 0
            if next_ts > block.timestamp:
                next_ts = block.timestamp
            else:
                vote_point.bias += self.vote_bias_changes[_gauge_addr][next_ts]
                dslope = self.vote_slope_changes[_gauge_addr][next_ts]
            vote_point.bias -= vote_point.slope * convert(next_ts - vote_point.ts, int128)
            if vote_point.bias < 0:
                vote_point.bias = 0
            vote_point.slope += dslope
            vote_point.ts = next_ts
            if next_ts == block.timestamp:
                break
        self.vote_points[_gauge_addr] = vote_point
        self.vote_enacted_at[_gauge_addr] = block.timestamp
        self._change_gauge_weight(_gauge_addr, convert(vote_point.bias, uint256))


@external
def enact_vote(_gauge_addr: address):
    self._enact_vote(_gauge_addr)


@external
def vote_for_gauge_weights(_gauge_addr: address, _user_weight: int128):
    """
    @notice Allocate voting power for changing pool weights
    @param _gauge_addr Gauge which `msg.sender` votes for
    @param _user_weight Weight for a gauge in bps (units of 0.01%). Minimal is 0.01%. Ignored if 0
    """
    escrow: address = self.voting_escrow
    slope: int128 = VotingEscrow(escrow).get_last_user_slope(msg.sender)
    lock_end: uint256 = VotingEscrow(escrow).locked__end(msg.sender)
    _n_gauges: int128 = self.n_gauges
    next_time: uint256 = (block.timestamp + WEEK) / WEEK * WEEK
    assert lock_end > next_time, "Your token lock expires too soon"
    assert self.gauge_types_[_gauge_addr] > 0, "Gauge not added"
    assert (_user_weight >= 0) and (_user_weight <= 10000), "You used all your voting power"
    assert block.timestamp >= self.last_user_vote[msg.sender][_gauge_addr] + WEIGHT_VOTE_DELAY, "Cannot vote so often"

    # Prepare slopes and biases in memory
    old_slope: VotedSlope = self.vote_user_slopes[msg.sender][_gauge_addr]
    old_dt: int128 = 0
    if old_slope.end > next_time:
        old_dt = convert(old_slope.end - next_time, int128)
    old_bias: int128 = old_slope.slope * old_dt
    new_slope: VotedSlope = VotedSlope({
        slope: slope * _user_weight / 10000,
        end: lock_end,
        power: _user_weight
    })
    new_dt: int128 = convert(lock_end - next_time, int128)  # dev: raises when expired
    new_bias: int128 = new_slope.slope * new_dt

    # Check and update powers (weights) used
    power_used: int128 = self.vote_user_power[msg.sender]
    power_used += (new_slope.power - old_slope.power)
    self.vote_user_power[msg.sender] = power_used
    assert (power_used >= 0) and (power_used <= 10000), 'Used too much power'

    self._enact_vote(_gauge_addr)

    ## Remove old and schedule new slope changes
    # Remove slope changes for old slopes
    # Schedule recording of initial slope for next_time
    self.vote_bias_changes[_gauge_addr][next_time] += new_bias - old_bias
    if old_slope.end > next_time:
        self.vote_slope_changes[_gauge_addr][next_time] += (new_slope.slope - old_slope.slope)
    else:
        self.vote_slope_changes[_gauge_addr][next_time] += new_slope.slope
    if old_slope.end > block.timestamp:
        # Cancel old slope changes if they still didn't happen
        self.vote_slope_changes[_gauge_addr][old_slope.end] += old_slope.slope
    # Add slope changes for new slopes
    self.vote_slope_changes[_gauge_addr][new_slope.end] -= new_slope.slope
    self.vote_user_slopes[msg.sender][_gauge_addr] = new_slope

    # Record last action time
    self.last_user_vote[msg.sender][_gauge_addr] = block.timestamp

    log VoteForGauge(block.timestamp, msg.sender, _gauge_addr, _user_weight)


@external
@view
def last_change() -> uint256:
    return self.period_timestamp[self.period]


@external
@view
def get_gauge_weight(addr: address) -> uint256:
    return self.gauge_weights[addr][self.gauge_last[addr]]


@external
@view
def get_type_weight(type_id: int128) -> uint256:
    return self.type_weights[type_id][self.type_last[type_id]]


@external
@view
def get_total_weight() -> uint256:
    return self.total_weight[self.period]


@external
@view
def get_weights_sum_per_type(type_id: int128) -> uint256:
    return self.weight_sums_per_type[type_id][self.type_last[type_id]]
