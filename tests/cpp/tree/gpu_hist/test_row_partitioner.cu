/*!
 * Copyright 2019-2022 by XGBoost Contributors
 */
#include <gtest/gtest.h>
#include <algorithm>
#include <vector>

#include <thrust/device_vector.h>
#include <thrust/host_vector.h>
#include <thrust/sequence.h>

#include "../../../../src/tree/gpu_hist/row_partitioner.cuh"
#include "../../helpers.h"
#include "xgboost/base.h"
#include "xgboost/generic_parameters.h"
#include "xgboost/task.h"
#include "xgboost/tree_model.h"

namespace xgboost {
namespace tree {

void TestSortPosition(const std::vector<int>& position_in, int left_idx,
                      int right_idx) {
  dh::safe_cuda(cudaSetDevice(0));
  std::vector<int64_t> left_count = {
      std::count(position_in.begin(), position_in.end(), left_idx)};
  dh::caching_device_vector<int64_t> d_left_count = left_count;
  dh::caching_device_vector<int> position = position_in;
  dh::caching_device_vector<int> position_out(position.size());

  dh::caching_device_vector<RowPartitioner::RowIndexT> ridx(position.size());
  thrust::sequence(ridx.begin(), ridx.end());
  dh::caching_device_vector<RowPartitioner::RowIndexT> ridx_out(ridx.size());
  RowPartitioner rp(0,10);
  rp.SortPosition(
      common::Span<int>(position.data().get(), position.size()),
      common::Span<int>(position_out.data().get(), position_out.size()),
      common::Span<RowPartitioner::RowIndexT>(ridx.data().get(), ridx.size()),
      common::Span<RowPartitioner::RowIndexT>(ridx_out.data().get(), ridx_out.size()), left_idx,
      right_idx, d_left_count.data().get(), nullptr);
  thrust::host_vector<int> position_result = position_out;
  thrust::host_vector<int> ridx_result = ridx_out;

  // Check position is sorted
  EXPECT_TRUE(std::is_sorted(position_result.begin(), position_result.end()));
  // Check row indices are sorted inside left and right segment
  EXPECT_TRUE(
      std::is_sorted(ridx_result.begin(), ridx_result.begin() + left_count[0]));
  EXPECT_TRUE(
      std::is_sorted(ridx_result.begin() + left_count[0], ridx_result.end()));

  // Check key value pairs are the same
  for (auto i = 0ull; i < ridx_result.size(); i++) {
    EXPECT_EQ(position_result[i], position_in[ridx_result[i]]);
  }
}
TEST(GpuHist, SortPosition) {
  TestSortPosition({1, 2, 1, 2, 1}, 1, 2);
  TestSortPosition({1, 1, 1, 1}, 1, 2);
  TestSortPosition({2, 2, 2, 2}, 1, 2);
  TestSortPosition({1, 2, 1, 2, 3}, 1, 2);
}

void TestUpdatePosition() {
  const int kNumRows = 10;
  RowPartitioner rp(0, kNumRows);
  auto rows = rp.GetRowsHost(0);
  EXPECT_EQ(rows.size(), kNumRows);
  for (auto i = 0ull; i < kNumRows; i++) {
    EXPECT_EQ(rows[i], i);
  }
  // Send the first five training instances to the right node
  // and the second 5 to the left node
  rp.UpdatePosition(0, 1, 2,
    [=] __device__(RowPartitioner::RowIndexT ridx) {
    if (ridx > 4) {
      return 1;
    }
    else {
      return 2;
    }
  });
  rows = rp.GetRowsHost(1);
  for (auto r : rows) {
    EXPECT_GT(r, 4);
  }
  rows = rp.GetRowsHost(2);
  for (auto r : rows) {
    EXPECT_LT(r, 5);
  }

  // Split the left node again
  rp.UpdatePosition(1, 3, 4, [=]__device__(RowPartitioner::RowIndexT ridx)
  {
    if (ridx < 7) {
      return 3
        ;
    }
    return 4;
  });
  EXPECT_EQ(rp.GetRows(3).size(), 2);
  EXPECT_EQ(rp.GetRows(4).size(), 3);
  // Check position is as expected
  EXPECT_EQ(rp.GetPositionHost(), std::vector<bst_node_t>({3,3,4,4,4,2,2,2,2,2}));
}

TEST(RowPartitioner, Basic) { TestUpdatePosition(); }

void TestFinalise() {
  const int kNumRows = 10;

  ObjInfo task{ObjInfo::kRegression, false, false};
  HostDeviceVector<bst_node_t> position;
  Context ctx;
  ctx.gpu_id = 0;

  {
    RowPartitioner rp(0, kNumRows);
    rp.FinalisePosition(
        &ctx, task, &position,
        [=] __device__(RowPartitioner::RowIndexT ridx, int position) { return 7; },
        [] XGBOOST_DEVICE(size_t idx) { return false; });

    auto position = rp.GetPositionHost();
    for (auto p : position) {
      EXPECT_EQ(p, 7);
    }
  }

  /**
   * Test for sampling.
   */
  dh::device_vector<float> hess(kNumRows);
  for (size_t i = 0; i < hess.size(); ++i) {
    // removed rows, 0, 3, 6, 9
    if (i % 3 == 0) {
      hess[i] = 0;
    } else {
      hess[i] = i;
    }
  }

  auto d_hess = dh::ToSpan(hess);

  RowPartitioner rp(0, kNumRows);
  rp.FinalisePosition(
      &ctx, task, &position,
      [] __device__(RowPartitioner::RowIndexT ridx, bst_node_t position) {
        return ridx % 2 == 0 ? 1 : 2;
      },
      [d_hess] __device__(size_t ridx) { return d_hess[ridx] - 0.f == 0.f; });

  auto const& h_position = position.ConstHostVector();
  for (size_t ridx = 0; ridx < h_position.size(); ++ridx) {
    if (ridx % 3 == 0) {
      ASSERT_LT(h_position[ridx], 0);
    } else {
      ASSERT_EQ(h_position[ridx], ridx % 2 == 0 ? 1 : 2);
    }
  }
}

TEST(RowPartitioner, Finalise) { TestFinalise(); }

void TestIncorrectRow() {
  RowPartitioner rp(0, 1);
  rp.UpdatePosition(0, 1, 2, [=]__device__ (RowPartitioner::RowIndexT ridx)
  {
    return 4; // This is not the left branch or the right branch
  });
}

TEST(RowPartitionerDeathTest, IncorrectRow) {
  ASSERT_DEATH({ TestIncorrectRow(); },".*");
}
}  // namespace tree
}  // namespace xgboost
